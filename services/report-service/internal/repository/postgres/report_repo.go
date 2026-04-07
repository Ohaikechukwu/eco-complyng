package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/report-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type reportRepository struct {
	db *gorm.DB
}

func NewReportRepository(db *gorm.DB) *reportRepository {
	return &reportRepository{db: db}
}

func (r *reportRepository) Create(ctx context.Context, report *domain.Report) error {
	return dbWithContext(ctx, r.db).Create(report).Error
}

func (r *reportRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Report, error) {
	var report domain.Report
	result := dbWithContext(ctx, r.db).Where("id = ?", id).First(&report)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &report, result.Error
}

func (r *reportRepository) FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Report, error) {
	var reports []domain.Report
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ?", inspectionID).
		Order("created_at DESC").
		Find(&reports)
	return reports, result.Error
}

func (r *reportRepository) FindByShareToken(ctx context.Context, token string) (*domain.Report, error) {
	var report domain.Report
	result := dbWithContext(ctx, r.db).
		Where("share_token = ?", token).
		First(&report)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &report, result.Error
}

func (r *reportRepository) Update(ctx context.Context, report *domain.Report) error {
	return dbWithContext(ctx, r.db).Save(report).Error
}
