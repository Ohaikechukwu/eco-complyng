package di

import (
	"fmt"

	"github.com/ecocomply/auth-service/internal/config"
	"github.com/ecocomply/auth-service/internal/handler"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/postgres"
	"github.com/ecocomply/auth-service/internal/service"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	gredis "github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config     *config.Config
	DB         *gorm.DB
	Redis      *gredis.Client
	JWTManager *sharedjwt.Manager
	TokenCache *cache.TokenCache

	UserRepo  irepository.UserRepository
	OrgRepo   irepository.OrgRepository
	TokenRepo irepository.TokenRepository

	AuthService  *service.AuthService
	CookieConfig handler.CookieConfig
}

func NewContainer(cfg *config.Config) (*Container, error) {
	dbCfg := sharedpostgres.Config{
		Host:     cfg.DBHost,
		Port:     cfg.DBPort,
		User:     cfg.DBUser,
		Password: cfg.DBPassword,
		DBName:   cfg.DBName,
	}

	db, err := sharedpostgres.Connect(dbCfg)
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
		WithAudience(cfg.JWTAudiences...).
		WithAccessTTL(cfg.AccessTokenTTL)
	tokenCache := cache.NewTokenCache(rdb)
	notificationClient := service.NewNotificationClient(cfg.NotificationServiceURL)

	orgRepo := postgres.NewOrgRepository(db)
	userRepo := postgres.NewUserRepository(db)
	tokenRepo := postgres.NewTokenRepository(db)

	authSvc := service.NewAuthService(
		db,
		userRepo, orgRepo, tokenRepo,
		tokenCache, jwtManager,
		notificationClient,
		cfg.AppBaseURL,
		cfg.RefreshTokenTTL,
	)

	cookieConfig := handler.CookieConfig{
		Domain:            cfg.CookieDomain,
		Secure:            cfg.CookieSecure,
		SameSite:          handler.ParseSameSite(cfg.CookieSameSite),
		AccessCookieName:  "access_token",
		RefreshCookieName: "refresh_token",
		CSRFCookieName:    "csrf_token",
		AccessCookiePath:  "/api/v1",
		RefreshCookiePath: "/api/v1/auth/refresh",
		CSRFCookiePath:    "/api/v1",
		AccessMaxAge:      cfg.AccessTokenTTL,
		RefreshMaxAge:     cfg.RefreshTokenTTL,
	}

	return &Container{
		Config:       cfg,
		DB:           db,
		Redis:        rdb,
		JWTManager:   jwtManager,
		TokenCache:   tokenCache,
		UserRepo:     userRepo,
		OrgRepo:      orgRepo,
		TokenRepo:    tokenRepo,
		AuthService:  authSvc,
		CookieConfig: cookieConfig,
	}, nil
}
