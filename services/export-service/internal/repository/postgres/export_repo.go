package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/export-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type exportRepository struct{ db *gorm.DB }

func NewExportRepository(db *gorm.DB) *exportRepository {
	return &exportRepository{db: db}
}

func (r *exportRepository) Create(ctx context.Context, job *domain.ExportJob) error {
	return dbWithContext(ctx, r.db).Create(job).Error
}

func (r *exportRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.ExportJob, error) {
	var job domain.ExportJob
	result := dbWithContext(ctx, r.db).Where("id = ?", id).First(&job)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &job, result.Error
}

func (r *exportRepository) Update(ctx context.Context, job *domain.ExportJob) error {
	return dbWithContext(ctx, r.db).Save(job).Error
}

func (r *exportRepository) List(ctx context.Context, limit, offset int) ([]domain.ExportJob, int64, error) {
	var jobs []domain.ExportJob
	var total int64
	dbWithContext(ctx, r.db).Model(&domain.ExportJob{}).Count(&total)
	result := dbWithContext(ctx, r.db).Order("created_at DESC").Limit(limit).Offset(offset).Find(&jobs)
	return jobs, total, result.Error
}
