package domain

import (
	"github.com/google/uuid"
	"time"
)

type ExportJobStatus string
type ExportJobType string

const (
	JobQueued  ExportJobStatus = "queued"
	JobRunning ExportJobStatus = "running"
	JobDone    ExportJobStatus = "done"
	JobFailed  ExportJobStatus = "failed"

	TypeDBBackup    ExportJobType = "db_backup"
	TypeReportBatch ExportJobType = "report_batch"
	TypeMediaExport ExportJobType = "media_export"
)

type ExportJob struct {
	ID         uuid.UUID       `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Type       ExportJobType   `gorm:"type:export_job_type;not null"`
	Status     ExportJobStatus `gorm:"type:export_job_status;not null;default:queued"`
	OrgSchema  string          `gorm:"not null"`
	FileURL    string
	Error      string
	StartedAt  *time.Time
	FinishedAt *time.Time
	CreatedBy  uuid.UUID `gorm:"type:uuid;not null"`
	CreatedAt  time.Time
}

func (ExportJob) TableName() string { return "export_jobs" }
