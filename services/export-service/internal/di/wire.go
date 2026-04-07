package di

import (
	"fmt"

	"github.com/ecocomply/export-service/internal/backup"
	"github.com/ecocomply/export-service/internal/config"
	irepository "github.com/ecocomply/export-service/internal/repository/interface"
	"github.com/ecocomply/export-service/internal/repository/postgres"
	"github.com/ecocomply/export-service/internal/service"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config        *config.Config
	DB            *gorm.DB
	Redis         *redis.Client
	JWTManager    *sharedjwt.Manager
	ExportRepo    irepository.ExportRepository
	ExportService *service.ExportService
}

func NewContainer(cfg *config.Config) (*Container, error) {
	db, err := sharedpostgres.Connect(sharedpostgres.Config{
		Host: cfg.DBHost, Port: cfg.DBPort,
		User: cfg.DBUser, Password: cfg.DBPassword, DBName: cfg.DBName,
	})
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}
	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host: cfg.RedisHost, Port: cfg.RedisPort, Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}
	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)
	dbCfg := sharedpostgres.Config{
		Host: cfg.DBHost, Port: cfg.DBPort,
		User: cfg.DBUser, Password: cfg.DBPassword, DBName: cfg.DBName,
	}
	dbBackup := &backup.DBBackup{
		Host: cfg.DBHost, Port: cfg.DBPort,
		User: cfg.DBUser, Password: cfg.DBPassword,
		DBName: cfg.DBName, OutDir: cfg.BackupDir,
	}
	exportRepo := postgres.NewExportRepository(db)
	exportSvc := service.NewExportService(exportRepo, dbBackup, dbCfg, cfg.BackupDir)

	return &Container{
		Config: cfg, DB: db, Redis: rdb,
		JWTManager:    jwtManager,
		ExportRepo:    exportRepo,
		ExportService: exportSvc,
	}, nil
}
