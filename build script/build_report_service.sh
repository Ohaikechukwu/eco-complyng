#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — report-service complete build script
# Run from inside ~/ecocomply-ng:
#   chmod +x build_report_service.sh && ./build_report_service.sh
# =============================================================================

BASE="services/report-service"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# 1. MIGRATIONS
# =============================================================================
info "Writing migrations..."

cat > "${BASE}/migrations/tenant/000001_create_reports.up.sql" << 'EOF'
-- =============================================================================
-- Migration: 000001_create_reports (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE report_status AS ENUM ('generating', 'ready', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS reports (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID            NOT NULL,
    generated_by    UUID            NOT NULL,
    status          report_status   NOT NULL DEFAULT 'generating',
    file_url        TEXT,
    file_size_bytes BIGINT,
    share_token     TEXT            UNIQUE,
    share_expiry    TIMESTAMPTZ,
    error_message   TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reports_inspection_id ON reports (inspection_id);
CREATE INDEX IF NOT EXISTS idx_reports_generated_by  ON reports (generated_by);
CREATE INDEX IF NOT EXISTS idx_reports_share_token   ON reports (share_token);
CREATE INDEX IF NOT EXISTS idx_reports_status        ON reports (status);

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_reports_updated_at
    BEFORE UPDATE ON reports
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
EOF

cat > "${BASE}/migrations/tenant/000001_create_reports.down.sql" << 'EOF'
DROP TRIGGER IF EXISTS set_reports_updated_at ON reports;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE  IF EXISTS reports;
DROP TYPE   IF EXISTS report_status;
EOF

log "Migrations done"

# =============================================================================
# 2. DOMAIN
# =============================================================================
info "Writing domain layer..."

cat > "${BASE}/internal/domain/report.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type ReportStatus string

const (
	ReportGenerating ReportStatus = "generating"
	ReportReady      ReportStatus = "ready"
	ReportFailed     ReportStatus = "failed"
)

type Report struct {
	ID             uuid.UUID    `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID   uuid.UUID    `gorm:"type:uuid;not null"`
	GeneratedBy    uuid.UUID    `gorm:"type:uuid;not null"`
	Status         ReportStatus `gorm:"type:report_status;not null;default:generating"`
	FileURL        string
	FileSizeBytes  int64
	ShareToken     string       `gorm:"uniqueIndex"`
	ShareExpiry    *time.Time
	ErrorMessage   string
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

func (Report) TableName() string { return "reports" }
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound       = errors.New("record not found")
	ErrUnauthorized   = errors.New("unauthorized")
	ErrForbidden      = errors.New("forbidden")
	ErrInvalidInput   = errors.New("invalid input")
	ErrInternalServer = errors.New("internal server error")
	ErrShareExpired   = errors.New("share link has expired")
	ErrReportNotReady = errors.New("report is not ready yet")
)
EOF

log "Domain done"

# =============================================================================
# 3. PDF TEMPLATE
# =============================================================================
info "Writing PDF HTML template..."

mkdir -p "${BASE}/internal/pdf/templates"

cat > "${BASE}/internal/pdf/templates/inspection_report.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Inspection Report — {{.ProjectName}}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: Arial, sans-serif; font-size: 13px; color: #1a1a1a; background: #fff; }

    .cover { padding: 60px 48px; border-bottom: 4px solid #2e7d32; }
    .cover h1 { font-size: 26px; color: #2e7d32; margin-bottom: 8px; }
    .cover .subtitle { font-size: 14px; color: #555; margin-bottom: 32px; }
    .cover table { width: 100%; border-collapse: collapse; }
    .cover table td { padding: 6px 0; vertical-align: top; }
    .cover table td:first-child { font-weight: bold; width: 180px; }

    .section { padding: 32px 48px; border-bottom: 1px solid #e0e0e0; }
    .section h2 { font-size: 15px; font-weight: bold; color: #2e7d32; text-transform: uppercase;
                  letter-spacing: 0.5px; margin-bottom: 16px; padding-bottom: 6px;
                  border-bottom: 2px solid #e8f5e9; }

    .checklist-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
    .checklist-table th { background: #e8f5e9; color: #2e7d32; text-align: left;
                          padding: 8px 10px; font-size: 12px; }
    .checklist-table td { padding: 8px 10px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
    .checklist-table tr:nth-child(even) td { background: #fafafa; }

    .badge { display: inline-block; padding: 2px 10px; border-radius: 12px;
             font-size: 11px; font-weight: bold; }
    .badge-yes  { background: #e8f5e9; color: #2e7d32; }
    .badge-no   { background: #ffebee; color: #c62828; }
    .badge-na   { background: #f5f5f5; color: #757575; }

    .actions-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
    .actions-table th { background: #fff3e0; color: #e65100; text-align: left;
                        padding: 8px 10px; font-size: 12px; }
    .actions-table td { padding: 8px 10px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }

    .status-pending   { color: #f57c00; font-weight: bold; }
    .status-resolved  { color: #2e7d32; font-weight: bold; }
    .status-overdue   { color: #c62828; font-weight: bold; }

    .media-grid { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 12px; }
    .media-item { width: 180px; }
    .media-item img { width: 100%; height: 130px; object-fit: cover;
                      border: 1px solid #e0e0e0; border-radius: 4px; }
    .media-item .caption { font-size: 10px; color: #888; margin-top: 4px; }

    .summary-box { display: flex; gap: 24px; margin-top: 8px; }
    .summary-card { flex: 1; padding: 16px; border-radius: 6px; text-align: center; }
    .summary-card .count { font-size: 28px; font-weight: bold; }
    .summary-card .label { font-size: 11px; color: #666; margin-top: 4px; }
    .card-green { background: #e8f5e9; color: #2e7d32; }
    .card-red   { background: #ffebee; color: #c62828; }
    .card-grey  { background: #f5f5f5; color: #555; }

    .footer { padding: 20px 48px; font-size: 11px; color: #999; text-align: center; }
  </style>
</head>
<body>

<!-- COVER -->
<div class="cover">
  <h1>Environmental Inspection Report</h1>
  <p class="subtitle">EcoComply NG — Generated Report</p>
  <table>
    <tr><td>Project</td><td>{{.ProjectName}}</td></tr>
    <tr><td>Location</td><td>{{.Location}}</td></tr>
    <tr><td>Inspection Date</td><td>{{.Date}}</td></tr>
    <tr><td>Inspector</td><td>{{.InspectorName}}</td></tr>
    <tr><td>Role</td><td>{{.InspectorRole}}</td></tr>
    <tr><td>Status</td><td>{{.Status}}</td></tr>
    <tr><td>Report Generated</td><td>{{.GeneratedAt}}</td></tr>
  </table>
</div>

<!-- SUMMARY -->
<div class="section">
  <h2>Compliance Summary</h2>
  <div class="summary-box">
    <div class="summary-card card-green">
      <div class="count">{{.ConformanceCount}}</div>
      <div class="label">Conformance</div>
    </div>
    <div class="summary-card card-red">
      <div class="count">{{.NonConformanceCount}}</div>
      <div class="label">Non-Conformance</div>
    </div>
    <div class="summary-card card-grey">
      <div class="count">{{.UnansweredCount}}</div>
      <div class="label">Unanswered</div>
    </div>
  </div>
</div>

<!-- CHECKLIST -->
<div class="section">
  <h2>Checklist Responses</h2>
  <table class="checklist-table">
    <thead>
      <tr>
        <th>#</th>
        <th>Item</th>
        <th>Response</th>
        <th>Comment</th>
      </tr>
    </thead>
    <tbody>
      {{range $i, $item := .ChecklistItems}}
      <tr>
        <td>{{inc $i}}</td>
        <td>{{$item.Description}}</td>
        <td>
          {{if eq $item.Response "yes"}}
            <span class="badge badge-yes">YES</span>
          {{else if eq $item.Response "no"}}
            <span class="badge badge-no">NO</span>
          {{else}}
            <span class="badge badge-na">N/A</span>
          {{end}}
        </td>
        <td>{{$item.Comment}}</td>
      </tr>
      {{end}}
    </tbody>
  </table>
</div>

<!-- AGREED ACTIONS -->
{{if .AgreedActions}}
<div class="section">
  <h2>Agreed Actions</h2>
  <table class="actions-table">
    <thead>
      <tr>
        <th>#</th>
        <th>Description</th>
        <th>Assignee</th>
        <th>Due Date</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
      {{range $i, $action := .AgreedActions}}
      <tr>
        <td>{{inc $i}}</td>
        <td>{{$action.Description}}</td>
        <td>{{$action.AssigneeID}}</td>
        <td>{{$action.DueDate}}</td>
        <td class="status-{{$action.Status}}">{{upper $action.Status}}</td>
      </tr>
      {{end}}
    </tbody>
  </table>
</div>
{{end}}

<!-- COMMENTS -->
{{if or .SupervisorComment .ManagerComment}}
<div class="section">
  <h2>Review Comments</h2>
  {{if .SupervisorComment}}
  <p><strong>Supervisor:</strong> {{.SupervisorComment}}</p>
  {{end}}
  {{if .ManagerComment}}
  <p style="margin-top:8px"><strong>Manager:</strong> {{.ManagerComment}}</p>
  {{end}}
</div>
{{end}}

<!-- MEDIA -->
{{if .MediaItems}}
<div class="section">
  <h2>Attached Photos</h2>
  <div class="media-grid">
    {{range .MediaItems}}
    <div class="media-item">
      <img src="{{.URL}}" alt="Inspection photo" />
      <div class="caption">{{.CapturedAt}} · {{.CapturedVia}}</div>
    </div>
    {{end}}
  </div>
</div>
{{end}}

<div class="footer">
  EcoComply NG · Report ID: {{.ReportID}} · {{.GeneratedAt}}
</div>

</body>
</html>
EOF

log "PDF template done"

# =============================================================================
# 4. PDF GENERATOR
# =============================================================================
info "Writing PDF generator..."

cat > "${BASE}/internal/pdf/generator.go" << 'EOF'
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
	ReportID           string
	ProjectName        string
	Location           string
	Date               string
	InspectorName      string
	InspectorRole      string
	Status             string
	GeneratedAt        string
	ConformanceCount   int
	NonConformanceCount int
	UnansweredCount    int
	SupervisorComment  string
	ManagerComment     string
	ChecklistItems     []ChecklistItemData
	AgreedActions      []ActionData
	MediaItems         []MediaData
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
EOF

log "PDF generator done"

# =============================================================================
# 5. DTOs
# =============================================================================
info "Writing DTOs..."

cat > "${BASE}/internal/dto/request/report_request.go" << 'EOF'
package request

// GenerateReportRequest triggers PDF generation for an inspection.
type GenerateReportRequest struct {
	InspectionID string `json:"inspection_id" binding:"required,uuid"`
}

// ShareReportRequest creates an expiring share link.
type ShareReportRequest struct {
	ExpiryHours int `json:"expiry_hours" binding:"required,min=1,max=720"` // max 30 days
}
EOF

cat > "${BASE}/internal/dto/response/report_response.go" << 'EOF'
package response

import "time"

type ReportResponse struct {
	ID           string     `json:"id"`
	InspectionID string     `json:"inspection_id"`
	GeneratedBy  string     `json:"generated_by"`
	Status       string     `json:"status"`
	FileURL      string     `json:"file_url,omitempty"`
	FileSizeBytes int64     `json:"file_size_bytes,omitempty"`
	ShareToken   string     `json:"share_token,omitempty"`
	ShareExpiry  *time.Time `json:"share_expiry,omitempty"`
	ErrorMessage string     `json:"error_message,omitempty"`
	CreatedAt    time.Time  `json:"created_at"`
}

type ShareLinkResponse struct {
	ShareURL    string    `json:"share_url"`
	ShareToken  string    `json:"share_token"`
	ExpiresAt   time.Time `json:"expires_at"`
}
EOF

log "DTOs done"

# =============================================================================
# 6. REPOSITORY
# =============================================================================
info "Writing repository..."

cat > "${BASE}/internal/repository/interface/report_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/report-service/internal/domain"
	"github.com/google/uuid"
)

type ReportRepository interface {
	Create(ctx context.Context, report *domain.Report) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Report, error)
	FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Report, error)
	FindByShareToken(ctx context.Context, token string) (*domain.Report, error)
	Update(ctx context.Context, report *domain.Report) error
}
EOF

cat > "${BASE}/internal/repository/postgres/report_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/report-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type reportRepository struct {
	db *gorm.DB
}

func NewReportRepository(db *gorm.DB) *reportRepository {
	return &reportRepository{db: db}
}

func (r *reportRepository) Create(ctx context.Context, report *domain.Report) error {
	return r.db.WithContext(ctx).Create(report).Error
}

func (r *reportRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Report, error) {
	var report domain.Report
	result := r.db.WithContext(ctx).Where("id = ?", id).First(&report)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &report, result.Error
}

func (r *reportRepository) FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Report, error) {
	var reports []domain.Report
	result := r.db.WithContext(ctx).
		Where("inspection_id = ?", inspectionID).
		Order("created_at DESC").
		Find(&reports)
	return reports, result.Error
}

func (r *reportRepository) FindByShareToken(ctx context.Context, token string) (*domain.Report, error) {
	var report domain.Report
	result := r.db.WithContext(ctx).
		Where("share_token = ?", token).
		First(&report)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &report, result.Error
}

func (r *reportRepository) Update(ctx context.Context, report *domain.Report) error {
	return r.db.WithContext(ctx).Save(report).Error
}
EOF

log "Repository done"

# =============================================================================
# 7. INSPECTION CLIENT (calls inspection-service internally)
# =============================================================================
info "Writing inspection client..."

mkdir -p "${BASE}/internal/client"

cat > "${BASE}/internal/client/inspection_client.go" << 'EOF'
package client

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// InspectionData is a minimal struct for what report-service needs from inspection-service.
type InspectionData struct {
	ID                  string              `json:"id"`
	ProjectName         string              `json:"project_name"`
	Location            string              `json:"location"`
	Date                time.Time           `json:"date"`
	InspectorName       string              `json:"inspector_name"`
	InspectorRole       string              `json:"inspector_role"`
	Status              string              `json:"status"`
	SupervisorComment   string              `json:"supervisor_comment"`
	ManagerComment      string              `json:"manager_comment"`
	ChecklistItems      []ChecklistItemData `json:"checklist_items"`
	AgreedActions       []ActionData        `json:"agreed_actions"`
}

type ChecklistItemData struct {
	Description string `json:"description"`
	Response    *bool  `json:"response"`
	Comment     string `json:"comment"`
}

type ActionData struct {
	Description string    `json:"description"`
	AssigneeID  string    `json:"assignee_id"`
	DueDate     time.Time `json:"due_date"`
	Status      string    `json:"status"`
}

// MediaData is fetched from media-service.
type MediaData struct {
	URL         string    `json:"url"`
	CapturedAt  time.Time `json:"captured_at"`
	CapturedVia string    `json:"captured_via"`
}

type InspectionClient struct {
	baseURL    string
	mediaURL   string
	httpClient *http.Client
}

func NewInspectionClient(inspectionServiceURL, mediaServiceURL string) *InspectionClient {
	return &InspectionClient{
		baseURL:  inspectionServiceURL,
		mediaURL: mediaServiceURL,
		httpClient: &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *InspectionClient) GetInspection(ctx context.Context, inspectionID, accessToken string) (*InspectionData, error) {
	url := fmt.Sprintf("%s/api/v1/inspections/%s", c.baseURL, inspectionID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("inspection fetch failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("inspection-service returned %d", resp.StatusCode)
	}

	var result struct {
		Data InspectionData `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return &result.Data, nil
}

func (c *InspectionClient) GetMedia(ctx context.Context, inspectionID, accessToken string) ([]MediaData, error) {
	url := fmt.Sprintf("%s/api/v1/media?inspection_id=%s", c.mediaURL, inspectionID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("media fetch failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("media-service returned %d", resp.StatusCode)
	}

	var result struct {
		Data struct {
			Media []MediaData `json:"media"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Data.Media, nil
}
EOF

log "Inspection client done"

# =============================================================================
# 8. SERVICE LAYER
# =============================================================================
info "Writing service layer..."

cat > "${BASE}/internal/service/report_service.go" << 'EOF'
package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"time"

	"github.com/ecocomply/report-service/internal/client"
	"github.com/ecocomply/report-service/internal/domain"
	"github.com/ecocomply/report-service/internal/dto/request"
	"github.com/ecocomply/report-service/internal/dto/response"
	"github.com/ecocomply/report-service/internal/pdf"
	irepository "github.com/ecocomply/report-service/internal/repository/interface"
	sharedcloudinary "github.com/ecocomply/shared/pkg/cloudinary"
	"github.com/google/uuid"
)

type ReportService struct {
	reportRepo         irepository.ReportRepository
	generator          *pdf.Generator
	cloudinary         *sharedcloudinary.Client
	inspectionClient   *client.InspectionClient
	appBaseURL         string
}

func NewReportService(
	reportRepo irepository.ReportRepository,
	generator *pdf.Generator,
	cloudinary *sharedcloudinary.Client,
	inspectionClient *client.InspectionClient,
	appBaseURL string,
) *ReportService {
	return &ReportService{
		reportRepo:       reportRepo,
		generator:        generator,
		cloudinary:       cloudinary,
		inspectionClient: inspectionClient,
		appBaseURL:       appBaseURL,
	}
}

// Generate creates a report record, generates the PDF asynchronously,
// and uploads it to Cloudinary.
func (s *ReportService) Generate(ctx context.Context, userID uuid.UUID, accessToken string, req request.GenerateReportRequest) (*response.ReportResponse, error) {
	inspectionID, err := uuid.Parse(req.InspectionID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}

	// 1. Create a report record with "generating" status
	report := &domain.Report{
		InspectionID: inspectionID,
		GeneratedBy:  userID,
		Status:       domain.ReportGenerating,
	}
	if err := s.reportRepo.Create(ctx, report); err != nil {
		return nil, err
	}

	// 2. Generate asynchronously
	go s.generateAsync(report.ID, inspectionID, accessToken)

	res := toReportResponse(report)
	return &res, nil
}

func (s *ReportService) generateAsync(reportID, inspectionID uuid.UUID, accessToken string) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	updateStatus := func(status domain.ReportStatus, errMsg string) {
		report, err := s.reportRepo.FindByID(ctx, reportID)
		if err != nil {
			return
		}
		report.Status = status
		report.ErrorMessage = errMsg
		_ = s.reportRepo.Update(ctx, report)
	}

	// Fetch inspection data
	inspection, err := s.inspectionClient.GetInspection(ctx, inspectionID.String(), accessToken)
	if err != nil {
		updateStatus(domain.ReportFailed, fmt.Sprintf("failed to fetch inspection: %s", err))
		return
	}

	// Fetch media
	mediaItems, _ := s.inspectionClient.GetMedia(ctx, inspectionID.String(), accessToken)

	// Build template data
	data := buildReportData(reportID.String(), inspection, mediaItems)

	// Generate PDF
	pdfBytes, err := s.generator.Generate(ctx, data)
	if err != nil {
		updateStatus(domain.ReportFailed, fmt.Sprintf("PDF generation failed: %s", err))
		return
	}

	// Write to temp file for Cloudinary upload
	tmpFile, err := os.CreateTemp("", "report-*.pdf")
	if err != nil {
		updateStatus(domain.ReportFailed, "temp file error")
		return
	}
	defer os.Remove(tmpFile.Name())
	tmpFile.Write(pdfBytes)
	tmpFile.Close()

	// Upload to Cloudinary
	f, err := os.Open(tmpFile.Name())
	if err != nil {
		updateStatus(domain.ReportFailed, "failed to open pdf for upload")
		return
	}
	defer f.Close()

	// Create a multipart-compatible wrapper
	result, err := s.cloudinary.UploadPDF(ctx, f, fmt.Sprintf("report_%s", reportID))
	if err != nil {
		updateStatus(domain.ReportFailed, fmt.Sprintf("cloudinary upload failed: %s", err))
		return
	}

	// Update report to ready
	report, _ := s.reportRepo.FindByID(ctx, reportID)
	report.Status = domain.ReportReady
	report.FileURL = result.URL
	report.FileSizeBytes = int64(len(pdfBytes))
	_ = s.reportRepo.Update(ctx, report)
}

// GetByInspection returns all reports for an inspection.
func (s *ReportService) GetByInspection(ctx context.Context, inspectionID uuid.UUID) ([]response.ReportResponse, error) {
	reports, err := s.reportRepo.FindByInspection(ctx, inspectionID)
	if err != nil {
		return nil, err
	}
	var res []response.ReportResponse
	for _, r := range reports {
		res = append(res, toReportResponse(&r))
	}
	return res, nil
}

// GetByID returns a single report.
func (s *ReportService) GetByID(ctx context.Context, id uuid.UUID) (*response.ReportResponse, error) {
	report, err := s.reportRepo.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if report.Status != domain.ReportReady {
		return nil, domain.ErrReportNotReady
	}
	res := toReportResponse(report)
	return &res, nil
}

// CreateShareLink generates an expiring share link for a report.
func (s *ReportService) CreateShareLink(ctx context.Context, reportID uuid.UUID, req request.ShareReportRequest) (*response.ShareLinkResponse, error) {
	report, err := s.reportRepo.FindByID(ctx, reportID)
	if err != nil {
		return nil, err
	}
	if report.Status != domain.ReportReady {
		return nil, domain.ErrReportNotReady
	}

	token := generateToken()
	expiry := time.Now().Add(time.Duration(req.ExpiryHours) * time.Hour)
	report.ShareToken = token
	report.ShareExpiry = &expiry

	if err := s.reportRepo.Update(ctx, report); err != nil {
		return nil, err
	}

	return &response.ShareLinkResponse{
		ShareURL:   fmt.Sprintf("%s/reports/share/%s", s.appBaseURL, token),
		ShareToken: token,
		ExpiresAt:  expiry,
	}, nil
}

// GetByShareToken validates and returns a report via its share token.
func (s *ReportService) GetByShareToken(ctx context.Context, token string) (*response.ReportResponse, error) {
	report, err := s.reportRepo.FindByShareToken(ctx, token)
	if err != nil {
		return nil, err
	}
	if report.ShareExpiry != nil && time.Now().After(*report.ShareExpiry) {
		return nil, domain.ErrShareExpired
	}
	res := toReportResponse(report)
	return &res, nil
}

// --- helpers ---

func buildReportData(reportID string, i *client.InspectionData, media []client.MediaData) pdf.ReportData {
	data := pdf.ReportData{
		ReportID:          reportID,
		ProjectName:       i.ProjectName,
		Location:          i.Location,
		Date:              i.Date.Format("02 Jan 2006"),
		InspectorName:     i.InspectorName,
		InspectorRole:     i.InspectorRole,
		Status:            i.Status,
		GeneratedAt:       time.Now().Format("02 Jan 2006 15:04"),
		SupervisorComment: i.SupervisorComment,
		ManagerComment:    i.ManagerComment,
	}

	for _, item := range i.ChecklistItems {
		resp := ""
		if item.Response != nil {
			if *item.Response {
				resp = "yes"
			} else {
				resp = "no"
			}
		}
		switch resp {
		case "yes":
			data.ConformanceCount++
		case "no":
			data.NonConformanceCount++
		default:
			data.UnansweredCount++
		}
		data.ChecklistItems = append(data.ChecklistItems, pdf.ChecklistItemData{
			Description: item.Description,
			Response:    resp,
			Comment:     item.Comment,
		})
	}

	for _, a := range i.AgreedActions {
		data.AgreedActions = append(data.AgreedActions, pdf.ActionData{
			Description: a.Description,
			AssigneeID:  a.AssigneeID,
			DueDate:     a.DueDate.Format("02 Jan 2006"),
			Status:      a.Status,
		})
	}

	for _, m := range media {
		data.MediaItems = append(data.MediaItems, pdf.MediaData{
			URL:         m.URL,
			CapturedAt:  m.CapturedAt.Format("02 Jan 2006 15:04"),
			CapturedVia: m.CapturedVia,
		})
	}

	return data
}

func generateToken() string {
	b := make([]byte, 24)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func toReportResponse(r *domain.Report) response.ReportResponse {
	return response.ReportResponse{
		ID:            r.ID.String(),
		InspectionID:  r.InspectionID.String(),
		GeneratedBy:   r.GeneratedBy.String(),
		Status:        string(r.Status),
		FileURL:       r.FileURL,
		FileSizeBytes: r.FileSizeBytes,
		ShareToken:    r.ShareToken,
		ShareExpiry:   r.ShareExpiry,
		ErrorMessage:  r.ErrorMessage,
		CreatedAt:     r.CreatedAt,
	}
}
EOF

log "Service layer done"

# =============================================================================
# 9. CLOUDINARY — add UploadPDF method to shared client
# =============================================================================
info "Adding UploadPDF to Cloudinary client..."

cat > shared/pkg/cloudinary/client.go << 'EOF'
package cloudinary

import (
	"context"
	"fmt"
	"io"
	"mime/multipart"

	"github.com/cloudinary/cloudinary-go/v2"
	"github.com/cloudinary/cloudinary-go/v2/api/uploader"
)

type Config struct {
	CloudName string
	APIKey    string
	APISecret string
	Folder    string
}

type UploadResult struct {
	PublicID string
	URL      string
	Bytes    int64
	Format   string
}

type Client struct {
	cld    *cloudinary.Cloudinary
	folder string
}

func NewClient(cfg Config) (*Client, error) {
	cld, err := cloudinary.NewFromParams(cfg.CloudName, cfg.APIKey, cfg.APISecret)
	if err != nil {
		return nil, fmt.Errorf("cloudinary init failed: %w", err)
	}
	return &Client{cld: cld, folder: cfg.Folder}, nil
}

// UploadFile uploads a multipart file (images).
func (c *Client) UploadFile(ctx context.Context, file multipart.File, filename string) (*UploadResult, error) {
	params := uploader.UploadParams{
		Folder:   c.folder,
		PublicID: filename,
	}
	result, err := c.cld.Upload.Upload(ctx, file, params)
	if err != nil {
		return nil, fmt.Errorf("cloudinary upload failed: %w", err)
	}
	return &UploadResult{
		PublicID: result.PublicID,
		URL:      result.SecureURL,
		Bytes:    int64(result.Bytes),
		Format:   result.Format,
	}, nil
}

// UploadPDF uploads a PDF file (reports).
func (c *Client) UploadPDF(ctx context.Context, file io.Reader, filename string) (*UploadResult, error) {
	params := uploader.UploadParams{
		Folder:       fmt.Sprintf("%s/reports", c.folder),
		PublicID:     filename,
		ResourceType: "raw", // PDFs must use "raw" resource type
	}
	result, err := c.cld.Upload.Upload(ctx, file, params)
	if err != nil {
		return nil, fmt.Errorf("cloudinary PDF upload failed: %w", err)
	}
	return &UploadResult{
		PublicID: result.PublicID,
		URL:      result.SecureURL,
		Bytes:    int64(result.Bytes),
		Format:   result.Format,
	}, nil
}

// DeleteFile removes a file from Cloudinary by its public ID.
func (c *Client) DeleteFile(ctx context.Context, publicID string) error {
	_, err := c.cld.Upload.Destroy(ctx, uploader.DestroyParams{PublicID: publicID})
	return err
}
EOF

log "Cloudinary UploadPDF added"

# =============================================================================
# 10. HANDLER
# =============================================================================
info "Writing handler..."

cat > "${BASE}/internal/handler/report_handler.go" << 'EOF'
package handler

import (
	"github.com/ecocomply/report-service/internal/domain"
	"github.com/ecocomply/report-service/internal/dto/request"
	"github.com/ecocomply/report-service/internal/handler/middleware"
	"github.com/ecocomply/report-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type ReportHandler struct {
	svc *service.ReportService
}

func NewReportHandler(svc *service.ReportService) *ReportHandler {
	return &ReportHandler{svc: svc}
}

// POST /api/v1/reports/generate
func (h *ReportHandler) Generate(c *gin.Context) {
	var req request.GenerateReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	accessToken := middleware.ExtractToken(c)

	res, err := h.svc.Generate(c.Request.Context(), userID, accessToken, req)
	if err != nil {
		handleError(c, err)
		return
	}
	response.Created(c, "report generation started", res)
}

// GET /api/v1/reports?inspection_id=xxx
func (h *ReportHandler) GetByInspection(c *gin.Context) {
	inspectionIDStr := c.Query("inspection_id")
	if inspectionIDStr == "" {
		response.BadRequest(c, "inspection_id is required")
		return
	}
	inspectionID, err := uuid.Parse(inspectionIDStr)
	if err != nil {
		response.BadRequest(c, "invalid inspection_id")
		return
	}
	res, err := h.svc.GetByInspection(c.Request.Context(), inspectionID)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "reports retrieved", res)
}

// GET /api/v1/reports/:id
func (h *ReportHandler) GetByID(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid report id")
		return
	}
	res, err := h.svc.GetByID(c.Request.Context(), id)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "report retrieved", res)
}

// POST /api/v1/reports/:id/share
func (h *ReportHandler) CreateShareLink(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid report id")
		return
	}
	var req request.ShareReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.CreateShareLink(c.Request.Context(), id, req)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "share link created", res)
}

// GET /api/v1/reports/share/:token  (public — no auth required)
func (h *ReportHandler) GetByShareToken(c *gin.Context) {
	token := c.Param("token")
	res, err := h.svc.GetByShareToken(c.Request.Context(), token)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "report retrieved", res)
}

func handleError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput:
		response.BadRequest(c, err.Error())
	case domain.ErrShareExpired:
		response.BadRequest(c, err.Error())
	case domain.ErrReportNotReady:
		c.JSON(202, gin.H{"success": false, "error": err.Error()})
	default:
		response.InternalError(c, "something went wrong")
	}
}
EOF

log "Handler done"

# =============================================================================
# 11. UPDATE AUTH MIDDLEWARE — expose ExtractToken publicly
# =============================================================================
cat > "${BASE}/internal/handler/middleware/auth.go" << 'EOF'
package middleware

import (
	"strings"

	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
)

const (
	ContextUserID    = "user_id"
	ContextUserName  = "user_name"
	ContextOrgID     = "org_id"
	ContextOrgSchema = "org_schema"
	ContextRole      = "role"
)

func Auth(jwtManager *sharedjwt.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := ExtractToken(c)
		if token == "" {
			response.Unauthorized(c, "missing token")
			c.Abort()
			return
		}
		claims, err := jwtManager.Verify(token)
		if err != nil {
			response.Unauthorized(c, "invalid or expired token")
			c.Abort()
			return
		}
		c.Set(ContextUserID, claims.UserID)
		c.Set(ContextOrgID, claims.OrgID)
		c.Set(ContextOrgSchema, claims.OrgSchema)
		c.Set(ContextRole, claims.Role)
		c.Next()
	}
}

func RequireRole(roles ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		role := c.GetString(ContextRole)
		for _, r := range roles {
			if r == role {
				c.Next()
				return
			}
		}
		response.Forbidden(c, "insufficient permissions")
		c.Abort()
	}
}

// ExtractToken is exported so handlers can pass the token to internal service clients.
func ExtractToken(c *gin.Context) string {
	bearer := c.GetHeader("Authorization")
	if strings.HasPrefix(bearer, "Bearer ") {
		return strings.TrimPrefix(bearer, "Bearer ")
	}
	cookie, err := c.Cookie("access_token")
	if err == nil {
		return cookie
	}
	return ""
}
EOF

# =============================================================================
# 12. ROUTER
# =============================================================================
info "Writing router..."

cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"github.com/ecocomply/report-service/internal/di"
	"github.com/ecocomply/report-service/internal/handler"
	"github.com/ecocomply/report-service/internal/handler/middleware"
	"github.com/gin-gonic/gin"
)

func New(c *di.Container) *gin.Engine {
	if c.Config.Env == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())
	r.Use(middleware.CORS())

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "report-service"})
	})

	h := handler.NewReportHandler(c.ReportService)

	v1 := r.Group("/api/v1/reports")
	{
		// Public — share link access
		v1.GET("/share/:token", h.GetByShareToken)

		// Protected
		protected := v1.Group("")
		protected.Use(middleware.Auth(c.JWTManager))
		protected.Use(middleware.Tenant(c.DB))
		{
			protected.POST("/generate", h.Generate)
			protected.GET("", h.GetByInspection)
			protected.GET("/:id", h.GetByID)
			protected.POST("/:id/share", h.CreateShareLink)
		}
	}

	return r
}
EOF

log "Router done"

# =============================================================================
# 13. DI / WIRE
# =============================================================================
info "Writing DI container..."

cat > "${BASE}/internal/di/wire.go" << 'EOF'
package di

import (
	"fmt"

	"github.com/ecocomply/report-service/internal/client"
	"github.com/ecocomply/report-service/internal/config"
	"github.com/ecocomply/report-service/internal/pdf"
	irepository "github.com/ecocomply/report-service/internal/repository/interface"
	"github.com/ecocomply/report-service/internal/repository/postgres"
	"github.com/ecocomply/report-service/internal/service"
	sharedcloudinary "github.com/ecocomply/shared/pkg/cloudinary"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config     *config.Config
	DB         *gorm.DB
	Redis      *redis.Client
	JWTManager *sharedjwt.Manager

	ReportRepo    irepository.ReportRepository
	ReportService *service.ReportService
}

func NewContainer(cfg *config.Config) (*Container, error) {
	db, err := sharedpostgres.Connect(sharedpostgres.Config{
		Host:     cfg.DBHost,
		Port:     cfg.DBPort,
		User:     cfg.DBUser,
		Password: cfg.DBPassword,
		DBName:   cfg.DBName,
	})
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}

	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host:     cfg.RedisHost,
		Port:     cfg.RedisPort,
		Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}

	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)

	cloudinaryClient, err := sharedcloudinary.NewClient(sharedcloudinary.Config{
		CloudName: cfg.CloudinaryCloudName,
		APIKey:    cfg.CloudinaryAPIKey,
		APISecret: cfg.CloudinaryAPISecret,
		Folder:    "ecocomply",
	})
	if err != nil {
		return nil, fmt.Errorf("cloudinary: %w", err)
	}

	generator := pdf.NewGenerator(cfg.TemplatePath)
	inspectionClient := client.NewInspectionClient(cfg.InspectionServiceURL, cfg.MediaServiceURL)
	reportRepo := postgres.NewReportRepository(db)
	reportSvc := service.NewReportService(reportRepo, generator, cloudinaryClient, inspectionClient, cfg.AppBaseURL)

	return &Container{
		Config:        cfg,
		DB:            db,
		Redis:         rdb,
		JWTManager:    jwtManager,
		ReportRepo:    reportRepo,
		ReportService: reportSvc,
	}, nil
}
EOF

log "DI container done"

# =============================================================================
# 14. CONFIG
# =============================================================================
info "Writing config..."

cat > "${BASE}/internal/config/config.go" << 'EOF'
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env                  string
	Port                 string
	GRPCPort             string
	DBHost               string
	DBPort               string
	DBName               string
	DBUser               string
	DBPassword           string
	RedisHost            string
	RedisPort            string
	RedisPass            string
	JWTSecret            string
	JWTExpiryHrs         int
	CloudinaryCloudName  string
	CloudinaryAPIKey     string
	CloudinaryAPISecret  string
	TemplatePath         string
	InspectionServiceURL string
	MediaServiceURL      string
	AppBaseURL           string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env:                  getEnv("ENV", "development"),
		Port:                 getEnv("PORT", "8084"),
		GRPCPort:             getEnv("GRPC_PORT", "50054"),
		DBHost:               getEnv("DB_HOST", "localhost"),
		DBPort:               getEnv("DB_PORT", "5432"),
		DBName:               getEnv("DB_NAME", "ecocomply"),
		DBUser:               getEnv("DB_USER", "postgres"),
		DBPassword:           getEnv("DB_PASSWORD", "secret"),
		RedisHost:            getEnv("REDIS_HOST", "localhost"),
		RedisPort:            getEnv("REDIS_PORT", "6379"),
		RedisPass:            getEnv("REDIS_PASS", ""),
		JWTSecret:            getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs:         expiry,
		CloudinaryCloudName:  getEnv("CLOUDINARY_CLOUD_NAME", ""),
		CloudinaryAPIKey:     getEnv("CLOUDINARY_API_KEY", ""),
		CloudinaryAPISecret:  getEnv("CLOUDINARY_API_SECRET", ""),
		TemplatePath:         getEnv("TEMPLATE_PATH", "./internal/pdf/templates"),
		InspectionServiceURL: getEnv("INSPECTION_SERVICE_URL", "http://localhost:8082"),
		MediaServiceURL:      getEnv("MEDIA_SERVICE_URL", "http://localhost:8083"),
		AppBaseURL:           getEnv("APP_BASE_URL", "http://localhost:8080"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF

cat > "${BASE}/.env.example" << 'EOF'
ENV=development
PORT=8084
GRPC_PORT=50054

DB_HOST=localhost
DB_PORT=5432
DB_NAME=ecocomply
DB_USER=postgres
DB_PASSWORD=secret

REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASS=

JWT_SECRET=change-me
JWT_EXPIRY_HOURS=24

CLOUDINARY_CLOUD_NAME=your_cloud_name
CLOUDINARY_API_KEY=your_api_key
CLOUDINARY_API_SECRET=your_api_secret

TEMPLATE_PATH=./internal/pdf/templates
INSPECTION_SERVICE_URL=http://localhost:8082
MEDIA_SERVICE_URL=http://localhost:8083
APP_BASE_URL=http://localhost:8080
EOF

# =============================================================================
# 15. go.mod
# =============================================================================
info "Writing go.mod..."

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/report-service

go 1.22

require (
	github.com/chromedp/cdproto v0.0.0-20240202021202-6d0b6a386732
	github.com/chromedp/chromedp v0.9.5
	github.com/cloudinary/cloudinary-go/v2 v2.7.0
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	github.com/stretchr/testify v1.9.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "go.mod done"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  report-service build complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Files written:"
find "${BASE}" -type f | sort | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "  1. cd ${BASE} && go mod tidy"
echo "  2. go build ./..."
echo ""
