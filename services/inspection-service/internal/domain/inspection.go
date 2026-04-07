package domain

import (
	"time"

	"github.com/google/uuid"
)

type InspectionStatus string

const (
	StatusDraft          InspectionStatus = "draft"
	StatusInProgress     InspectionStatus = "in_progress"
	StatusSubmitted      InspectionStatus = "submitted"
	StatusUnderReview    InspectionStatus = "under_review"
	StatusPendingActions InspectionStatus = "pending_actions"
	StatusCompleted      InspectionStatus = "completed"
	StatusFinalized      InspectionStatus = "finalized"
)

// ValidTransitions defines allowed status moves.
var ValidTransitions = map[InspectionStatus][]InspectionStatus{
	StatusDraft:          {StatusInProgress},
	StatusInProgress:     {StatusSubmitted},
	StatusSubmitted:      {StatusUnderReview},
	StatusUnderReview:    {StatusPendingActions, StatusCompleted},
	StatusPendingActions: {StatusUnderReview, StatusCompleted},
	StatusCompleted:      {StatusFinalized},
	StatusFinalized:      {},
}

func (s InspectionStatus) CanTransitionTo(next InspectionStatus) bool {
	for _, allowed := range ValidTransitions[s] {
		if allowed == next {
			return true
		}
	}
	return false
}

type Inspection struct {
	ID             uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	ProjectName    string    `gorm:"not null"`
	LocationName   string
	Latitude       *float64
	Longitude      *float64
	Date           time.Time        `gorm:"not null"`
	InspectorName  string           `gorm:"not null"`
	InspectorRole  string           `gorm:"not null"`
	AssignedUserID uuid.UUID        `gorm:"type:uuid;not null"`
	ChecklistID    *uuid.UUID       `gorm:"type:uuid"`
	Status         InspectionStatus `gorm:"type:inspection_status;not null;default:draft"`
	Notes          string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	DeletedAt      *time.Time `gorm:"index"`

	// Associations (loaded on demand)
	ChecklistItems []ChecklistItem     `gorm:"foreignKey:InspectionID"`
	AgreedActions  []AgreedAction      `gorm:"foreignKey:InspectionID"`
	Comments       []InspectionComment `gorm:"foreignKey:InspectionID"`
	Reviews        []InspectionReview  `gorm:"foreignKey:InspectionID"`
}

func (Inspection) TableName() string { return "inspections" }
