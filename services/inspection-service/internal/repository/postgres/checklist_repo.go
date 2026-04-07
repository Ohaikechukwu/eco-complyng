package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type checklistRepository struct {
	db *gorm.DB
}

func NewChecklistRepository(db *gorm.DB) *checklistRepository {
	return &checklistRepository{db: db}
}

func (r *checklistRepository) CreateTemplate(ctx context.Context, t *domain.ChecklistTemplate) error {
	return dbWithContext(ctx, r.db).Create(t).Error
}

func (r *checklistRepository) FindTemplateByID(ctx context.Context, id uuid.UUID) (*domain.ChecklistTemplate, error) {
	var t domain.ChecklistTemplate
	result := dbWithContext(ctx, r.db).
		Preload("Items").
		Where("id = ? AND deleted_at IS NULL", id).
		First(&t)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &t, result.Error
}

func (r *checklistRepository) ListTemplates(ctx context.Context) ([]domain.ChecklistTemplate, error) {
	var templates []domain.ChecklistTemplate
	result := dbWithContext(ctx, r.db).
		Preload("Items").
		Where("deleted_at IS NULL").
		Order("is_system DESC, name ASC").
		Find(&templates)
	return templates, result.Error
}

func (r *checklistRepository) DeleteTemplate(ctx context.Context, id uuid.UUID) error {
	return dbWithContext(ctx, r.db).
		Model(&domain.ChecklistTemplate{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}

func (r *checklistRepository) CreateItems(ctx context.Context, items []domain.ChecklistItem) error {
	if len(items) == 0 {
		return nil
	}
	return dbWithContext(ctx, r.db).CreateInBatches(items, 100).Error
}

func (r *checklistRepository) FindItemsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.ChecklistItem, error) {
	var items []domain.ChecklistItem
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ?", inspectionID).
		Order("sort_order ASC").
		Find(&items)
	return items, result.Error
}

func (r *checklistRepository) FindItemByID(ctx context.Context, itemID uuid.UUID) (*domain.ChecklistItem, error) {
	var item domain.ChecklistItem
	result := dbWithContext(ctx, r.db).
		Where("id = ?", itemID).
		First(&item)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &item, result.Error
}

func (r *checklistRepository) UpdateItem(ctx context.Context, item *domain.ChecklistItem) error {
	return dbWithContext(ctx, r.db).Save(item).Error
}

func (r *checklistRepository) AddItem(ctx context.Context, item *domain.ChecklistItem) error {
	return dbWithContext(ctx, r.db).Create(item).Error
}
