package di

import (
	"fmt"

	"github.com/ecocomply/collaboration-service/internal/config"
	irepository "github.com/ecocomply/collaboration-service/internal/repository/interface"
	"github.com/ecocomply/collaboration-service/internal/repository/postgres"
	"github.com/ecocomply/collaboration-service/internal/service"
	"github.com/ecocomply/collaboration-service/internal/ws"
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
	Hub           *ws.Hub
	SessionRepo   irepository.SessionRepository
	CollabService *service.CollabService
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
	hub := ws.NewHub()
	go hub.Run()

	sessionRepo := postgres.NewSessionRepository(db)
	collabSvc := service.NewCollabService(sessionRepo)

	return &Container{
		Config:        cfg,
		DB:            db,
		Redis:         rdb,
		JWTManager:    jwtManager,
		Hub:           hub,
		SessionRepo:   sessionRepo,
		CollabService: collabSvc,
	}, nil
}
