package di

import (
	"fmt"

	"github.com/ecocomply/inspection-service/internal/config"
	irepository "github.com/ecocomply/inspection-service/internal/repository/interface"
	"github.com/ecocomply/inspection-service/internal/repository/postgres"
	"github.com/ecocomply/inspection-service/internal/service"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config     *config.Config
	DB         *gorm.DB
	Redis      *redis.Client
	JWTManager *sharedjwt.Manager

	InspectionRepo irepository.InspectionRepository
	ChecklistRepo  irepository.ChecklistRepository
	ActionRepo     irepository.ActionRepository

	InspectionService *service.InspectionService
}

func NewContainer(cfg *config.Config) (*Container, error) {
	db, err := sharedpostgres.Connect(sharedpostgres.Config{
		Host:     cfg.DBHost,
		Port:     cfg.DBPort,
		User:     cfg.DBUser,
		Password: cfg.DBPassword,
		DBName:   cfg.DBName,
	})
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}

	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host:     cfg.RedisHost,
		Port:     cfg.RedisPort,
		Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}

	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs).
		WithIssuer(cfg.JWTIssuer).
		WithAudience(cfg.JWTAudiences...)

	inspectionRepo := postgres.NewInspectionRepository(db)
	checklistRepo := postgres.NewChecklistRepository(db)
	actionRepo := postgres.NewActionRepository(db)

	inspectionSvc := service.NewInspectionService(inspectionRepo, checklistRepo, actionRepo)

	return &Container{
		Config:            cfg,
		DB:                db,
		Redis:             rdb,
		JWTManager:        jwtManager,
		InspectionRepo:    inspectionRepo,
		ChecklistRepo:     checklistRepo,
		ActionRepo:        actionRepo,
		InspectionService: inspectionSvc,
	}, nil
}
