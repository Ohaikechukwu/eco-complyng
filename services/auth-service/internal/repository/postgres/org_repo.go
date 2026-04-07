package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type orgRepository struct {
	db *gorm.DB
}

func NewOrgRepository(db *gorm.DB) *orgRepository {
	return &orgRepository{db: db}
}

func (r *orgRepository) Create(ctx context.Context, org *domain.Org) error {
	result := dbWithContext(ctx, r.db).Create(org)
	if result.Error != nil {
		if isUniqueViolation(result.Error) {
			return domain.ErrAlreadyExists
		}
		return result.Error
	}
	return nil
}

func (r *orgRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Org, error) {
	var org domain.Org
	result := dbWithContext(ctx, r.db).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&org)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &org, result.Error
}

func (r *orgRepository) FindByEmail(ctx context.Context, email string) (*domain.Org, error) {
	var org domain.Org
	result := dbWithContext(ctx, r.db).
		Where("email = ? AND deleted_at IS NULL", email).
		First(&org)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &org, result.Error
}

func (r *orgRepository) FindBySchemaName(ctx context.Context, schemaName string) (*domain.Org, error) {
	var org domain.Org
	result := dbWithContext(ctx, r.db).
		Where("schema_name = ? AND deleted_at IS NULL", schemaName).
		First(&org)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &org, result.Error
}

func (r *orgRepository) Update(ctx context.Context, org *domain.Org) error {
	return dbWithContext(ctx, r.db).Save(org).Error
}

// ProvisionSchema calls the stored procedure that creates the org's
// isolated Postgres schema with all required tables in one transaction.
func (r *orgRepository) ProvisionSchema(ctx context.Context, schemaName string) error {
	return dbWithContext(ctx, r.db).
		Exec("SELECT provision_org_schema(?)", schemaName).Error
}
