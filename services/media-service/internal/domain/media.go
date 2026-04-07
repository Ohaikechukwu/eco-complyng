package domain

import (
	"time"

	"github.com/google/uuid"
)

type CaptureSource string
type GPSSource string

const (
	SourceCamera  CaptureSource = "camera"
	SourceGallery CaptureSource = "gallery"

	GPSDevice GPSSource = "device"
	GPSManual GPSSource = "manual"
	GPSNone   GPSSource = "none"
)

type Media struct {
	ID           uuid.UUID     `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID     `gorm:"type:uuid;not null"`
	UploadedBy   uuid.UUID     `gorm:"type:uuid;not null"`
	CloudinaryID string        `gorm:"uniqueIndex;not null"`
	URL          string        `gorm:"not null"`
	Filename     string        `gorm:"not null"`
	MimeType     string        `gorm:"not null"`
	SizeBytes    int64         `gorm:"not null;default:0"`
	CapturedVia  CaptureSource `gorm:"type:capture_source;not null"`
	Latitude     *float64
	Longitude    *float64
	GPSSource    GPSSource `gorm:"type:gps_source;not null;default:none"`
	CapturedAt   time.Time `gorm:"not null"`
	CreatedAt    time.Time
	DeletedAt    *time.Time `gorm:"index"`
}

func (Media) TableName() string { return "media" }
