package postgres

import (
	"context"
	"strings"

	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	"gorm.io/gorm"
)

func dbWithContext(ctx context.Context, db *gorm.DB) *gorm.DB {
	return sharedpostgres.FromContext(ctx, db).WithContext(ctx)
}

// isUniqueViolation checks if a Postgres error is a unique constraint violation (code 23505).
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "23505") ||
		strings.Contains(err.Error(), "unique constraint") ||
		strings.Contains(err.Error(), "duplicate key")
}
