package di

import (
	"fmt"

	"github.com/ecocomply/media-service/internal/config"
	irepository "github.com/ecocomply/media-service/internal/repository/interface"
	"github.com/ecocomply/media-service/internal/repository/postgres"
	"github.com/ecocomply/media-service/internal/service"
	sharedcloudinary "github.com/ecocomply/shared/pkg/cloudinary"
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

	MediaRepo    irepository.MediaRepository
	MediaService *service.MediaService
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

	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)

	cloudinaryClient, err := sharedcloudinary.NewClient(sharedcloudinary.Config{
		CloudName: cfg.CloudinaryCloudName,
		APIKey:    cfg.CloudinaryAPIKey,
		APISecret: cfg.CloudinaryAPISecret,
		Folder:    "ecocomply/inspections",
	})
	if err != nil {
		return nil, fmt.Errorf("cloudinary: %w", err)
	}

	mediaRepo := postgres.NewMediaRepository(db)
	mediaSvc := service.NewMediaService(mediaRepo, cloudinaryClient)

	return &Container{
		Config:       cfg,
		DB:           db,
		Redis:        rdb,
		JWTManager:   jwtManager,
		MediaRepo:    mediaRepo,
		MediaService: mediaSvc,
	}, nil
}
