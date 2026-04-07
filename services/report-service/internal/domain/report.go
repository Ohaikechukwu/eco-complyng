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
	ID            uuid.UUID    `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID  uuid.UUID    `gorm:"type:uuid;not null"`
	GeneratedBy   uuid.UUID    `gorm:"type:uuid;not null"`
	Status        ReportStatus `gorm:"type:report_status;not null;default:generating"`
	FileURL       string
	FileSizeBytes int64
	ShareToken    string `gorm:"uniqueIndex"`
	ShareExpiry   *time.Time
	ErrorMessage  string
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

func (Report) TableName() string { return "reports" }
