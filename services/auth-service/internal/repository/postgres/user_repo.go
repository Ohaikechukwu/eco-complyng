package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type userRepository struct {
	db *gorm.DB
}

func NewUserRepository(db *gorm.DB) *userRepository {
	return &userRepository{db: db}
}

func (r *userRepository) Create(ctx context.Context, user *domain.User) error {
	result := dbWithContext(ctx, r.db).Create(user)
	if result.Error != nil {
		if isUniqueViolation(result.Error) {
			return domain.ErrAlreadyExists
		}
		return result.Error
	}
	return nil
}

func (r *userRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.User, error) {
	var user domain.User
	result := dbWithContext(ctx, r.db).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&user)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &user, result.Error
}

func (r *userRepository) FindByEmail(ctx context.Context, email string) (*domain.User, error) {
	var user domain.User
	result := dbWithContext(ctx, r.db).
		Where("email = ? AND deleted_at IS NULL", email).
		First(&user)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &user, result.Error
}

func (r *userRepository) Update(ctx context.Context, user *domain.User) error {
	return dbWithContext(ctx, r.db).Save(user).Error
}

func (r *userRepository) SoftDelete(ctx context.Context, id uuid.UUID) error {
	return dbWithContext(ctx, r.db).
		Model(&domain.User{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}

func (r *userRepository) List(ctx context.Context, limit, offset int) ([]domain.User, int64, error) {
	var users []domain.User
	var total int64

	dbWithContext(ctx, r.db).Model(&domain.User{}).
		Where("deleted_at IS NULL").
		Count(&total)

	result := dbWithContext(ctx, r.db).
		Where("deleted_at IS NULL").
		Order("created_at DESC").
		Limit(limit).Offset(offset).
		Find(&users)

	return users, total, result.Error
}
