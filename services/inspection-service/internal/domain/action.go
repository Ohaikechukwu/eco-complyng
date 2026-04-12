package domain

import (
	"time"

	"github.com/google/uuid"
)

type ActionStatus string

const (
	ActionPending    ActionStatus = "pending"
	ActionInProgress ActionStatus = "in_progress"
	ActionResolved   ActionStatus = "resolved"
	ActionOverdue    ActionStatus = "overdue"
)

type AgreedAction struct {
	ID           uuid.UUID    `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID    `gorm:"type:uuid;not null"`
	Description  string       `gorm:"not null"`
	AssigneeID   uuid.UUID    `gorm:"type:uuid;not null"`
	DueDate      time.Time    `gorm:"not null"`
	Status       ActionStatus `gorm:"type:action_status;not null;default:pending"`
	EvidenceURL  string
	ResolvedAt   *time.Time
	CreatedBy    uuid.UUID `gorm:"type:uuid;not null"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (AgreedAction) TableName() string { return "agreed_actions" }

type InspectionComment struct {
	ID           uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID `gorm:"type:uuid;not null"`
	AuthorID     uuid.UUID `gorm:"type:uuid;not null"`
	Body         string    `gorm:"not null"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
	DeletedAt    *time.Time `gorm:"index"`
}

func (InspectionComment) TableName() string { return "inspection_comments" }

type ReviewStage string
type ReviewStatus string

const (
	ReviewStageSupervisor ReviewStage = "supervisor"
	ReviewStageManager    ReviewStage = "manager"

	ReviewOpen      ReviewStatus = "open"
	ReviewAddressed ReviewStatus = "addressed"
	ReviewApproved  ReviewStatus = "approved"
	ReviewRejected  ReviewStatus = "rejected"
)

type InspectionReview struct {
	ID              uuid.UUID    `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID    uuid.UUID    `gorm:"type:uuid;not null"`
	Stage           ReviewStage  `gorm:"type:review_stage;not null"`
	ReviewerID      uuid.UUID    `gorm:"type:uuid;not null"`
	AssignedToID    uuid.UUID    `gorm:"type:uuid;not null"`
	Comment         string       `gorm:"not null"`
	DueDate         time.Time    `gorm:"not null"`
	Status          ReviewStatus `gorm:"type:review_status;not null;default:open"`
	ResponseComment string
	ResolvedAt      *time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

func (InspectionReview) TableName() string { return "inspection_reviews" }
