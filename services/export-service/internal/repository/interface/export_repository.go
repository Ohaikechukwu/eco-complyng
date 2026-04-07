package irepository

import (
	"context"
	"github.com/ecocomply/export-service/internal/domain"
	"github.com/google/uuid"
)

type ExportRepository interface {
	Create(ctx context.Context, job *domain.ExportJob) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.ExportJob, error)
	Update(ctx context.Context, job *domain.ExportJob) error
	List(ctx context.Context, limit, offset int) ([]domain.ExportJob, int64, error)
}
