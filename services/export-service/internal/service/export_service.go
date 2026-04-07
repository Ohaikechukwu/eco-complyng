package service

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/ecocomply/export-service/internal/backup"
	"github.com/ecocomply/export-service/internal/domain"
	"github.com/ecocomply/export-service/internal/dto/request"
	"github.com/ecocomply/export-service/internal/dto/response"
	irepository "github.com/ecocomply/export-service/internal/repository/interface"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	"github.com/google/uuid"
)

type ExportService struct {
	repo     irepository.ExportRepository
	dbBackup *backup.DBBackup
	dbCfg    sharedpostgres.Config
	outDir   string
}

func NewExportService(repo irepository.ExportRepository, dbBackup *backup.DBBackup, dbCfg sharedpostgres.Config, outDir string) *ExportService {
	return &ExportService{repo: repo, dbBackup: dbBackup, dbCfg: dbCfg, outDir: outDir}
}

func (s *ExportService) CreateJob(ctx context.Context, userID uuid.UUID, orgSchema string, req request.CreateExportJobRequest) (*response.ExportJobResponse, error) {
	job := &domain.ExportJob{
		Type:      domain.ExportJobType(req.Type),
		Status:    domain.JobQueued,
		OrgSchema: orgSchema,
		CreatedBy: userID,
	}
	if err := s.repo.Create(ctx, job); err != nil {
		return nil, err
	}

	go s.runJob(job.ID)

	res := toResponse(job)
	return &res, nil
}

func (s *ExportService) List(ctx context.Context, limit, offset int) ([]response.ExportJobResponse, int64, error) {
	jobs, total, err := s.repo.List(ctx, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	var res []response.ExportJobResponse
	for _, j := range jobs {
		res = append(res, toResponse(&j))
	}
	return res, total, nil
}

func (s *ExportService) runJob(jobID uuid.UUID) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	job, err := s.repo.FindByID(ctx, jobID)
	if err != nil {
		return
	}

	now := time.Now()
	job.Status = domain.JobRunning
	job.StartedAt = &now
	_ = s.repo.Update(ctx, job)

	var fileURL string
	var runErr error

	switch job.Type {
	case domain.TypeDBBackup:
		fileURL, runErr = s.dbBackup.Run(ctx)
	case domain.TypeReportBatch:
		fileURL, runErr = s.exportReports(ctx, job.OrgSchema)
	case domain.TypeMediaExport:
		fileURL, runErr = s.exportMedia(ctx, job.OrgSchema)
	default:
		runErr = fmt.Errorf("job type %s not yet implemented", job.Type)
	}

	finished := time.Now()
	job.FinishedAt = &finished

	if runErr != nil {
		job.Status = domain.JobFailed
		job.Error = runErr.Error()
	} else {
		job.Status = domain.JobDone
		job.FileURL = fileURL
	}

	_ = s.repo.Update(ctx, job)
}

func (s *ExportService) exportReports(ctx context.Context, schema string) (string, error) {
	db, err := sharedpostgres.ConnectWithSchema(s.dbCfg, schema)
	if err != nil {
		return "", err
	}
	type row struct {
		ReportID      string    `json:"report_id"`
		InspectionID  string    `json:"inspection_id"`
		ProjectName   string    `json:"project_name"`
		Status        string    `json:"status"`
		FileURL       string    `json:"file_url"`
		ShareToken    string    `json:"share_token"`
		ShareExpiry   *time.Time `json:"share_expiry,omitempty"`
		CreatedAt     time.Time `json:"created_at"`
	}
	var rows []row
	query := `
		SELECT r.id::text AS report_id,
		       r.inspection_id::text AS inspection_id,
		       i.project_name,
		       r.status,
		       COALESCE(r.file_url, '') AS file_url,
		       COALESCE(r.share_token, '') AS share_token,
		       r.share_expiry,
		       r.created_at
		FROM reports r
		LEFT JOIN inspections i ON i.id = r.inspection_id
		ORDER BY r.created_at DESC`
	if err := db.WithContext(ctx).Raw(query).Scan(&rows).Error; err != nil {
		return "", err
	}
	return s.writeJSONExport("report_batch", schema, rows)
}

func (s *ExportService) exportMedia(ctx context.Context, schema string) (string, error) {
	db, err := sharedpostgres.ConnectWithSchema(s.dbCfg, schema)
	if err != nil {
		return "", err
	}
	type row struct {
		MediaID       string     `json:"media_id"`
		InspectionID  string     `json:"inspection_id"`
		ProjectName   string     `json:"project_name"`
		URL           string     `json:"url"`
		Filename      string     `json:"filename"`
		MimeType      string     `json:"mime_type"`
		CapturedVia   string     `json:"captured_via"`
		Latitude      *float64   `json:"latitude,omitempty"`
		Longitude     *float64   `json:"longitude,omitempty"`
		CapturedAt    time.Time  `json:"captured_at"`
	}
	var rows []row
	query := `
		SELECT m.id::text AS media_id,
		       m.inspection_id::text AS inspection_id,
		       i.project_name,
		       m.url,
		       m.filename,
		       m.mime_type,
		       m.captured_via,
		       m.latitude,
		       m.longitude,
		       m.captured_at
		FROM media m
		LEFT JOIN inspections i ON i.id = m.inspection_id
		WHERE m.deleted_at IS NULL
		ORDER BY m.created_at DESC`
	if err := db.WithContext(ctx).Raw(query).Scan(&rows).Error; err != nil {
		return "", err
	}
	return s.writeJSONExport("media_export", schema, rows)
}

func (s *ExportService) writeJSONExport(prefix, schema string, payload interface{}) (string, error) {
	if err := os.MkdirAll(s.outDir, 0755); err != nil {
		return "", err
	}
	filename := filepath.Join(s.outDir, fmt.Sprintf("%s_%s_%s.json", prefix, schema, time.Now().Format("20060102_150405")))
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filename, data, 0644); err != nil {
		return "", err
	}
	return filename, nil
}

func toResponse(j *domain.ExportJob) response.ExportJobResponse {
	return response.ExportJobResponse{
		ID:         j.ID.String(),
		Type:       string(j.Type),
		Status:     string(j.Status),
		FileURL:    j.FileURL,
		Error:      j.Error,
		StartedAt:  j.StartedAt,
		FinishedAt: j.FinishedAt,
		CreatedAt:  j.CreatedAt,
	}
}
