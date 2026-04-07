package postgres

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/ecocomply/inspection-service/internal/domain"
	irepository "github.com/ecocomply/inspection-service/internal/repository/interface"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type inspectionRepository struct {
	db *gorm.DB
}

func NewInspectionRepository(db *gorm.DB) *inspectionRepository {
	return &inspectionRepository{db: db}
}

func (r *inspectionRepository) Create(ctx context.Context, i *domain.Inspection) error {
	return dbWithContext(ctx, r.db).Create(i).Error
}

func (r *inspectionRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Inspection, error) {
	var i domain.Inspection
	result := dbWithContext(ctx, r.db).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&i)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &i, result.Error
}

func (r *inspectionRepository) FindByIDWithDetails(ctx context.Context, id uuid.UUID) (*domain.Inspection, error) {
	var i domain.Inspection
	result := dbWithContext(ctx, r.db).
		Preload("ChecklistItems").
		Preload("AgreedActions").
		Preload("Comments").
		Preload("Reviews").
		Where("id = ? AND deleted_at IS NULL", id).
		First(&i)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &i, result.Error
}

func (r *inspectionRepository) Update(ctx context.Context, i *domain.Inspection) error {
	return dbWithContext(ctx, r.db).Save(i).Error
}

func (r *inspectionRepository) SoftDelete(ctx context.Context, id uuid.UUID) error {
	return dbWithContext(ctx, r.db).
		Model(&domain.Inspection{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}

func (r *inspectionRepository) List(ctx context.Context, f irepository.ListFilters) ([]domain.Inspection, int64, error) {
	db := dbWithContext(ctx, r.db)
	var items []domain.Inspection
	var total int64

	q := db.Model(&domain.Inspection{}).
		Where("deleted_at IS NULL")

	if f.Role == "enumerator" {
		q = q.Where("assigned_user_id = ?", f.UserID)
	}

	if f.Status != "" {
		q = q.Where("status = ?", f.Status)
	}

	if f.Search != "" {
		term := "%" + strings.ToLower(f.Search) + "%"
		q = q.Where("LOWER(project_name) LIKE ? OR LOWER(location_name) LIKE ?", term, term)
	}

	if err := q.Count(&total).Error; err != nil {
		return nil, 0, err
	}

	result := q.Order("created_at DESC").
		Limit(f.Limit).Offset(f.Offset).
		Find(&items)

	return items, total, result.Error
}

func (r *inspectionRepository) Dashboard(ctx context.Context, userID uuid.UUID, role string) (*irepository.DashboardCounts, error) {
	db := dbWithContext(ctx, r.db)
	counts := &irepository.DashboardCounts{}
	statuses := []struct {
		field  *int64
		status string
	}{
		{&counts.Total, ""},
		{&counts.Draft, "draft"},
		{&counts.InProgress, "in_progress"},
		{&counts.Submitted, "submitted"},
		{&counts.UnderReview, "under_review"},
		{&counts.PendingActions, "pending_actions"},
		{&counts.Completed, "completed"},
		{&counts.Finalized, "finalized"},
	}

	for _, item := range statuses {
		q := db.Model(&domain.Inspection{}).Where("deleted_at IS NULL")
		if role == "enumerator" {
			q = q.Where("assigned_user_id = ?", userID)
		}
		if item.status != "" {
			q = q.Where("status = ?", item.status)
		}
		if err := q.Count(item.field).Error; err != nil {
			return nil, err
		}
	}

	return counts, nil
}

func (r *inspectionRepository) FindChangedSince(ctx context.Context, since time.Time, userID uuid.UUID, role string) ([]domain.Inspection, error) {
	q := dbWithContext(ctx, r.db).Where("updated_at > ? AND deleted_at IS NULL", since)
	if role == "enumerator" {
		q = q.Where("assigned_user_id = ?", userID)
	}
	var inspections []domain.Inspection
	if err := q.Order("updated_at ASC").Find(&inspections).Error; err != nil {
		return nil, err
	}
	return inspections, nil
}

func (r *inspectionRepository) FindDeletedSince(ctx context.Context, since time.Time, userID uuid.UUID, role string) ([]uuid.UUID, error) {
	type row struct{ ID uuid.UUID }
	q := dbWithContext(ctx, r.db).Model(&domain.Inspection{}).Select("id").Where("deleted_at > ?", since)
	if role == "enumerator" {
		q = q.Where("assigned_user_id = ?", userID)
	}
	var rows []row
	if err := q.Find(&rows).Error; err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	return ids, nil
}
