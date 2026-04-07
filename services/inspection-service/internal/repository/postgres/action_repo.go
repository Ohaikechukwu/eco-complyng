package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type actionRepository struct {
	db *gorm.DB
}

func NewActionRepository(db *gorm.DB) *actionRepository {
	return &actionRepository{db: db}
}

func (r *actionRepository) Create(ctx context.Context, a *domain.AgreedAction) error {
	return dbWithContext(ctx, r.db).Create(a).Error
}

func (r *actionRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.AgreedAction, error) {
	var a domain.AgreedAction
	result := dbWithContext(ctx, r.db).Where("id = ?", id).First(&a)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &a, result.Error
}

func (r *actionRepository) FindByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.AgreedAction, error) {
	var actions []domain.AgreedAction
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ?", inspectionID).
		Order("due_date ASC").
		Find(&actions)
	return actions, result.Error
}

func (r *actionRepository) Update(ctx context.Context, a *domain.AgreedAction) error {
	return dbWithContext(ctx, r.db).Save(a).Error
}

func (r *actionRepository) AddComment(ctx context.Context, c *domain.InspectionComment) error {
	return dbWithContext(ctx, r.db).Create(c).Error
}

func (r *actionRepository) FindCommentsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.InspectionComment, error) {
	var comments []domain.InspectionComment
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ? AND deleted_at IS NULL", inspectionID).
		Order("created_at ASC").
		Find(&comments)
	return comments, result.Error
}

func (r *actionRepository) CreateReview(ctx context.Context, review *domain.InspectionReview) error {
	return dbWithContext(ctx, r.db).Create(review).Error
}

func (r *actionRepository) FindReviewByID(ctx context.Context, id uuid.UUID) (*domain.InspectionReview, error) {
	var review domain.InspectionReview
	result := dbWithContext(ctx, r.db).Where("id = ?", id).First(&review)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &review, result.Error
}

func (r *actionRepository) FindReviewsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.InspectionReview, error) {
	var reviews []domain.InspectionReview
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ?", inspectionID).
		Order("created_at ASC").
		Find(&reviews)
	return reviews, result.Error
}

func (r *actionRepository) UpdateReview(ctx context.Context, review *domain.InspectionReview) error {
	return dbWithContext(ctx, r.db).Save(review).Error
}
