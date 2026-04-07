package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/media-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type mediaRepository struct {
	db *gorm.DB
}

func NewMediaRepository(db *gorm.DB) *mediaRepository {
	return &mediaRepository{db: db}
}

func (r *mediaRepository) Create(ctx context.Context, media *domain.Media) error {
	return dbWithContext(ctx, r.db).Create(media).Error
}

func (r *mediaRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Media, error) {
	var media domain.Media
	result := dbWithContext(ctx, r.db).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&media)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &media, result.Error
}

func (r *mediaRepository) FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Media, int64, error) {
	var media []domain.Media
	var total int64

	dbWithContext(ctx, r.db).Model(&domain.Media{}).
		Where("inspection_id = ? AND deleted_at IS NULL", inspectionID).
		Count(&total)

	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ? AND deleted_at IS NULL", inspectionID).
		Order("captured_at DESC").
		Find(&media)

	return media, total, result.Error
}

func (r *mediaRepository) SoftDelete(ctx context.Context, id uuid.UUID) error {
	return dbWithContext(ctx, r.db).
		Model(&domain.Media{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}
