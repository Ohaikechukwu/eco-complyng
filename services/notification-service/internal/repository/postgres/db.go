package postgres

import (
	"context"

	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	"gorm.io/gorm"
)

func dbWithContext(ctx context.Context, db *gorm.DB) *gorm.DB {
	return sharedpostgres.FromContext(ctx, db).WithContext(ctx)
}
