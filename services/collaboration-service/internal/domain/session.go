package domain

import (
	"github.com/google/uuid"
	"time"
)

type CollabSession struct {
	ID           uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID `gorm:"type:uuid;not null;uniqueIndex"`
	CreatedBy    uuid.UUID `gorm:"type:uuid;not null"`
	IsActive     bool      `gorm:"not null;default:true"`
	CreatedAt    time.Time
}

func (CollabSession) TableName() string { return "collab_sessions" }

type CollabParticipant struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	SessionID uuid.UUID `gorm:"type:uuid;not null"`
	UserID    uuid.UUID `gorm:"type:uuid;not null"`
	JoinedAt  time.Time `gorm:"not null"`
}

func (CollabParticipant) TableName() string { return "collab_participants" }

type CollabEvent struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	SessionID uuid.UUID `gorm:"type:uuid;not null"`
	UserID    uuid.UUID `gorm:"type:uuid;not null"`
	EventType string    `gorm:"not null"`
	Payload   []byte    `gorm:"type:jsonb"`
	CreatedAt time.Time
}

func (CollabEvent) TableName() string { return "collab_events" }

type PermissionLevel string
type AccessStatus string

const (
	PermissionViewer  PermissionLevel = "viewer"
	PermissionEditor  PermissionLevel = "editor"
	PermissionReviewer PermissionLevel = "reviewer"

	AccessPending AccessStatus = "pending"
	AccessActive  AccessStatus = "active"
	AccessRevoked AccessStatus = "revoked"
)

type CollabAccess struct {
	ID           uuid.UUID       `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID       `gorm:"type:uuid;not null"`
	UserID       uuid.UUID       `gorm:"type:uuid;not null"`
	Permission   PermissionLevel `gorm:"type:permission_level;not null"`
	Status       AccessStatus    `gorm:"type:access_status;not null;default:pending"`
	InvitedBy    uuid.UUID       `gorm:"type:uuid;not null"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (CollabAccess) TableName() string { return "collab_access" }
