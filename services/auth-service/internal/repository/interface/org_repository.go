package irepository

import (
	"context"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
)

// OrgRepository defines all data access operations for orgs.
// Operates on the public schema — no tenant scoping needed.
type OrgRepository interface {
	Create(ctx context.Context, org *domain.Org) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Org, error)
	FindByEmail(ctx context.Context, email string) (*domain.Org, error)
	FindBySchemaName(ctx context.Context, schemaName string) (*domain.Org, error)
	Update(ctx context.Context, org *domain.Org) error
	ProvisionSchema(ctx context.Context, schemaName string) error
}
