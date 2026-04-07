package pdf

import (
	"bytes"
	"context"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"
)

// ReportData is the data model passed to the HTML template.
type ReportData struct {
	ReportID            string
	ProjectName         string
	Location            string
	Date                string
	InspectorName       string
	InspectorRole       string
	Status              string
	GeneratedAt         string
	ConformanceCount    int
	NonConformanceCount int
	UnansweredCount     int
	ConformanceAreas    []ChecklistItemData
	NonConformanceAreas []ChecklistItemData
	ChecklistItems      []ChecklistItemData
	AgreedActions       []ActionData
	ReviewComments      []ReviewCommentData
	MediaItems          []MediaData
}

type ChecklistItemData struct {
	Description string
	Response    string // "yes", "no", or ""
	Comment     string
}

type ActionData struct {
	Description string
	AssigneeID  string
	DueDate     string
	Status      string
}

type MediaData struct {
	URL         string
	CapturedAt  string
	CapturedVia string
}

type ReviewCommentData struct {
	Body      string
	CreatedAt string
}

// Generator handles HTML template rendering and PDF generation via chromedp.
type Generator struct {
	templatePath string
}

func NewGenerator(templatePath string) *Generator {
	return &Generator{templatePath: templatePath}
}

// Generate renders the HTML template with data and converts it to PDF bytes.
func (g *Generator) Generate(ctx context.Context, data ReportData) ([]byte, error) {
	// 1. Render HTML template
	html, err := g.renderTemplate(data)
	if err != nil {
		return nil, fmt.Errorf("template render failed: %w", err)
	}

	// 2. Write HTML to a temp file (chromedp needs a file:// URL)
	tmpFile, err := os.CreateTemp("", "report-*.html")
	if err != nil {
		return nil, fmt.Errorf("temp file creation failed: %w", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(html); err != nil {
		return nil, err
	}
	tmpFile.Close()

	// 3. Generate PDF via chromedp
	pdfBytes, err := g.htmlToPDF(ctx, tmpFile.Name())
	if err != nil {
		return nil, fmt.Errorf("pdf generation failed: %w", err)
	}

	return pdfBytes, nil
}

func (g *Generator) renderTemplate(data ReportData) (string, error) {
	funcMap := template.FuncMap{
		"inc":   func(i int) int { return i + 1 },
		"upper": strings.ToUpper,
	}

	tmplPath := filepath.Join(g.templatePath, "inspection_report.html")
	tmpl, err := template.New("inspection_report.html").Funcs(funcMap).ParseFiles(tmplPath)
	if err != nil {
		return "", err
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func (g *Generator) htmlToPDF(ctx context.Context, htmlFilePath string) ([]byte, error) {
	// Create a chromedp context with timeout
	allocCtx, cancel := chromedp.NewExecAllocator(ctx,
		chromedp.NoSandbox,
		chromedp.Headless,
		chromedp.DisableGPU,
		chromedp.Flag("disable-software-rasterizer", true),
		chromedp.Flag("disable-dev-shm-usage", true),
	)
	defer cancel()

	chromedpCtx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()

	timeoutCtx, cancel := context.WithTimeout(chromedpCtx, 30*time.Second)
	defer cancel()

	fileURL := fmt.Sprintf("file://%s", htmlFilePath)
	var pdfBuf []byte

	err := chromedp.Run(timeoutCtx,
		chromedp.Navigate(fileURL),
		chromedp.WaitReady("body"),
		chromedp.ActionFunc(func(ctx context.Context) error {
			var err error
			pdfBuf, _, err = page.PrintToPDF().
				WithPrintBackground(true).
				WithPaperWidth(8.27).   // A4 width in inches
				WithPaperHeight(11.69). // A4 height in inches
				WithMarginTop(0.4).
				WithMarginBottom(0.4).
				WithMarginLeft(0.4).
				WithMarginRight(0.4).
				Do(ctx)
			return err
		}),
	)

	return pdfBuf, err
}
