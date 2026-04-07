package irepository

import (
	"context"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
)

type ChecklistRepository interface {
	// Templates
	CreateTemplate(ctx context.Context, t *domain.ChecklistTemplate) error
	FindTemplateByID(ctx context.Context, id uuid.UUID) (*domain.ChecklistTemplate, error)
	ListTemplates(ctx context.Context) ([]domain.ChecklistTemplate, error)
	DeleteTemplate(ctx context.Context, id uuid.UUID) error

	// Checklist items on inspections
	CreateItems(ctx context.Context, items []domain.ChecklistItem) error
	FindItemsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.ChecklistItem, error)
	FindItemByID(ctx context.Context, itemID uuid.UUID) (*domain.ChecklistItem, error)
	UpdateItem(ctx context.Context, item *domain.ChecklistItem) error
	AddItem(ctx context.Context, item *domain.ChecklistItem) error
}
