package domain

import (
	"time"

	"github.com/google/uuid"
)

type ChecklistTemplate struct {
	ID          uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Name        string    `gorm:"not null"`
	Description string
	IsSystem    bool       `gorm:"not null;default:false"`
	ClonedFrom  *uuid.UUID `gorm:"type:uuid"`
	CreatedBy   uuid.UUID  `gorm:"type:uuid;not null"`
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   *time.Time              `gorm:"index"`
	Items       []ChecklistTemplateItem `gorm:"foreignKey:TemplateID"`
}

func (ChecklistTemplate) TableName() string { return "checklist_templates" }

type ChecklistTemplateItem struct {
	ID          uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	TemplateID  uuid.UUID `gorm:"type:uuid;not null"`
	Description string    `gorm:"not null"`
	SortOrder   int
	CreatedAt   time.Time
}

func (ChecklistTemplateItem) TableName() string { return "checklist_template_items" }

type ChecklistItem struct {
	ID             uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID   uuid.UUID  `gorm:"type:uuid;not null"`
	TemplateItemID *uuid.UUID `gorm:"type:uuid"`
	Description    string     `gorm:"not null"`
	Response       *bool
	Comment        string
	SortOrder      int
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

func (ChecklistItem) TableName() string { return "checklist_items" }
