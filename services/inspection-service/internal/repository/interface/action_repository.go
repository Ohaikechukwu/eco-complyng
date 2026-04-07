package irepository

import (
	"context"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
)

type ActionRepository interface {
	Create(ctx context.Context, action *domain.AgreedAction) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.AgreedAction, error)
	FindByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.AgreedAction, error)
	Update(ctx context.Context, action *domain.AgreedAction) error

	// Comments
	AddComment(ctx context.Context, comment *domain.InspectionComment) error
	FindCommentsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.InspectionComment, error)
	CreateReview(ctx context.Context, review *domain.InspectionReview) error
	FindReviewByID(ctx context.Context, id uuid.UUID) (*domain.InspectionReview, error)
	FindReviewsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.InspectionReview, error)
	UpdateReview(ctx context.Context, review *domain.InspectionReview) error
}
