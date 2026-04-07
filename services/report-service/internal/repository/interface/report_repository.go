package irepository

import (
	"context"

	"github.com/ecocomply/report-service/internal/domain"
	"github.com/google/uuid"
)

type ReportRepository interface {
	Create(ctx context.Context, report *domain.Report) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Report, error)
	FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Report, error)
	FindByShareToken(ctx context.Context, token string) (*domain.Report, error)
	Update(ctx context.Context, report *domain.Report) error
}
