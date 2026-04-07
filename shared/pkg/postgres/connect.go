package postgres

import (
	"context"
	"errors"
	"fmt"
	"regexp"

	"github.com/gin-gonic/gin"
	gormpostgres "gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type Config struct {
	Host     string
	Port     string
	User     string
	Password string
	DBName   string
}

var ErrInvalidSchemaName = errors.New("invalid schema name")

type tenantDBKey struct{}

var schemaNamePattern = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

func Connect(cfg Config) (*gorm.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable TimeZone=UTC",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.DBName,
	)
	return gorm.Open(gormpostgres.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Info),
	})
}

// WithSchema opens a new DB connection scoped to the given schema.
func WithSchema(db *gorm.DB, schema string) *gorm.DB {
	return db.Session(&gorm.Session{NewDB: true, SkipDefaultTransaction: true}).
		Table("").
		Set("search_path", schema)
}

// ConnectWithSchema opens a dedicated connection with search_path set.
func ConnectWithSchema(cfg Config, schema string) (*gorm.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable TimeZone=UTC search_path=%s,public",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.DBName, schema,
	)
	return gorm.Open(gormpostgres.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Info),
	})
}

func ContextWithDB(ctx context.Context, db *gorm.DB) context.Context {
	return context.WithValue(ctx, tenantDBKey{}, db)
}

func FromContext(ctx context.Context, fallback *gorm.DB) *gorm.DB {
	if db, ok := ctx.Value(tenantDBKey{}).(*gorm.DB); ok && db != nil {
		return db
	}
	return fallback
}

func BeginTenantTx(ctx context.Context, db *gorm.DB, schema string) (*gorm.DB, error) {
	if !schemaNamePattern.MatchString(schema) {
		return nil, ErrInvalidSchemaName
	}

	tx := db.WithContext(ctx).Begin()
	if tx.Error != nil {
		return nil, tx.Error
	}

	searchPath := fmt.Sprintf("%s,public", schema)
	if err := tx.Exec("SELECT set_config('search_path', ?, true)", searchPath).Error; err != nil {
		_ = tx.Rollback().Error
		return nil, err
	}

	return tx, nil
}

func AttachTenantRequest(c *gin.Context, db *gorm.DB, schema string) (*gorm.DB, error) {
	tx, err := BeginTenantTx(c.Request.Context(), db, schema)
	if err != nil {
		return nil, err
	}

	c.Request = c.Request.WithContext(ContextWithDB(c.Request.Context(), tx))
	return tx, nil
}

func FinalizeTenantRequest(c *gin.Context, tx *gorm.DB) error {
	if len(c.Errors) > 0 || c.Writer.Status() >= 500 {
		return tx.Rollback().Error
	}

	if err := tx.Commit().Error; err != nil {
		_ = tx.Rollback().Error
		return err
	}

	return nil
}
