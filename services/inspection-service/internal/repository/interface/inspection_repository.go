package irepository

import (
	"context"
	"time"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
)

type InspectionRepository interface {
	Create(ctx context.Context, inspection *domain.Inspection) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Inspection, error)
	FindByIDWithDetails(ctx context.Context, id uuid.UUID) (*domain.Inspection, error)
	Update(ctx context.Context, inspection *domain.Inspection) error
	SoftDelete(ctx context.Context, id uuid.UUID) error
	List(ctx context.Context, filters ListFilters) ([]domain.Inspection, int64, error)
	Dashboard(ctx context.Context, userID uuid.UUID, role string) (*DashboardCounts, error)
	FindChangedSince(ctx context.Context, since time.Time, userID uuid.UUID, role string) ([]domain.Inspection, error)
	FindDeletedSince(ctx context.Context, since time.Time, userID uuid.UUID, role string) ([]uuid.UUID, error)
}

type ListFilters struct {
	Status string
	Search string
	UserID uuid.UUID
	Role   string
	Limit  int
	Offset int
}

type DashboardCounts struct {
	Total          int64
	Draft          int64
	InProgress     int64
	Submitted      int64
	UnderReview    int64
	PendingActions int64
	Completed      int64
	Finalized      int64
}
