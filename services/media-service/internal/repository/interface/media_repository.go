package irepository

import (
	"context"

	"github.com/ecocomply/media-service/internal/domain"
	"github.com/google/uuid"
)

type MediaRepository interface {
	Create(ctx context.Context, media *domain.Media) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Media, error)
	FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Media, int64, error)
	SoftDelete(ctx context.Context, id uuid.UUID) error
}
