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
	reportRepo       irepository.ReportRepository
	generator        *pdf.Generator
	cloudinary       *sharedcloudinary.Client
	inspectionClient *client.InspectionClient
	appBaseURL       string
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
		Location:          i.LocationName,
		Date:              i.Date.Format("02 Jan 2006"),
		InspectorName:     i.InspectorName,
		InspectorRole:     i.InspectorRole,
		Status:            i.Status,
		GeneratedAt:       time.Now().Format("02 Jan 2006 15:04"),
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
			data.ConformanceAreas = append(data.ConformanceAreas, pdf.ChecklistItemData{
				Description: item.Description,
				Response:    resp,
				Comment:     item.Comment,
			})
		case "no":
			data.NonConformanceCount++
			data.NonConformanceAreas = append(data.NonConformanceAreas, pdf.ChecklistItemData{
				Description: item.Description,
				Response:    resp,
				Comment:     item.Comment,
			})
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

	for _, comment := range i.Comments {
		data.ReviewComments = append(data.ReviewComments, pdf.ReviewCommentData{
			Body:      comment.Body,
			CreatedAt: comment.CreatedAt.Format("02 Jan 2006 15:04"),
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
