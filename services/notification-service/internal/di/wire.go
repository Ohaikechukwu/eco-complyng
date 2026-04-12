package di

import (
	"fmt"

	"github.com/ecocomply/notification-service/internal/config"
	"github.com/ecocomply/notification-service/internal/email"
	irepository "github.com/ecocomply/notification-service/internal/repository/interface"
	"github.com/ecocomply/notification-service/internal/repository/postgres"
	"github.com/ecocomply/notification-service/internal/service"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config              *config.Config
	DB                  *gorm.DB
	Redis               *redis.Client
	JWTManager          *sharedjwt.Manager
	NotificationRepo    irepository.NotificationRepository
	NotificationService *service.NotificationService
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
	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs).
		WithIssuer(cfg.JWTIssuer).
		WithAudience(cfg.JWTAudiences...)
	sender := email.NewSender(email.Config{
		SMTPHost:     cfg.SMTPHost,
		SMTPPort:     cfg.SMTPPort,
		SMTPUser:     cfg.SMTPUser,
		SMTPPassword: cfg.SMTPPassword,
		FromAddress:  cfg.FromAddress,
		TemplatePath: cfg.TemplatePath,
	})
	notificationRepo := postgres.NewNotificationRepository(db)
	notificationSvc := service.NewNotificationService(notificationRepo, sender)

	return &Container{
		Config: cfg, DB: db, Redis: rdb,
		JWTManager:          jwtManager,
		NotificationRepo:    notificationRepo,
		NotificationService: notificationSvc,
	}, nil
}
