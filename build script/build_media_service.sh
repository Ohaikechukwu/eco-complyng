#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — media-service complete build script
# Run from inside ~/ecocomply-ng:
#   chmod +x build_media_service.sh && ./build_media_service.sh
# =============================================================================

BASE="services/media-service"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# 1. MIGRATIONS
# =============================================================================
info "Writing migrations..."

cat > "${BASE}/migrations/tenant/000001_create_media.up.sql" << 'EOF'
-- =============================================================================
-- Migration: 000001_create_media (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- ENUM: capture source
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE capture_source AS ENUM ('camera', 'gallery');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- ENUM: gps source
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE gps_source AS ENUM ('device', 'manual', 'none');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- TABLE: media
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS media (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID            NOT NULL,
    uploaded_by     UUID            NOT NULL,
    cloudinary_id   TEXT            NOT NULL UNIQUE,
    url             TEXT            NOT NULL,
    filename        TEXT            NOT NULL,
    mime_type       TEXT            NOT NULL,
    size_bytes      BIGINT          NOT NULL DEFAULT 0,
    captured_via    capture_source  NOT NULL,
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,
    gps_source      gps_source      NOT NULL DEFAULT 'none',
    captured_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_media_inspection_id ON media (inspection_id);
CREATE INDEX IF NOT EXISTS idx_media_uploaded_by   ON media (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_media_deleted_at    ON media (deleted_at);
CREATE INDEX IF NOT EXISTS idx_media_captured_at   ON media (captured_at DESC);
EOF

cat > "${BASE}/migrations/tenant/000001_create_media.down.sql" << 'EOF'
DROP TABLE  IF EXISTS media;
DROP TYPE   IF EXISTS gps_source;
DROP TYPE   IF EXISTS capture_source;
EOF

log "Migrations done"

# =============================================================================
# 2. DOMAIN
# =============================================================================
info "Writing domain layer..."

cat > "${BASE}/internal/domain/media.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type CaptureSource string
type GPSSource string

const (
	SourceCamera  CaptureSource = "camera"
	SourceGallery CaptureSource = "gallery"

	GPSDevice GPSSource = "device"
	GPSManual GPSSource = "manual"
	GPSNone   GPSSource = "none"
)

type Media struct {
	ID           uuid.UUID     `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID     `gorm:"type:uuid;not null"`
	UploadedBy   uuid.UUID     `gorm:"type:uuid;not null"`
	CloudinaryID string        `gorm:"uniqueIndex;not null"`
	URL          string        `gorm:"not null"`
	Filename     string        `gorm:"not null"`
	MimeType     string        `gorm:"not null"`
	SizeBytes    int64         `gorm:"not null;default:0"`
	CapturedVia  CaptureSource `gorm:"type:capture_source;not null"`
	Latitude     *float64
	Longitude    *float64
	GPSSource    GPSSource     `gorm:"type:gps_source;not null;default:none"`
	CapturedAt   time.Time     `gorm:"not null"`
	CreatedAt    time.Time
	DeletedAt    *time.Time    `gorm:"index"`
}

func (Media) TableName() string { return "media" }
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound       = errors.New("record not found")
	ErrUnauthorized   = errors.New("unauthorized")
	ErrForbidden      = errors.New("forbidden")
	ErrInvalidInput   = errors.New("invalid input")
	ErrInternalServer = errors.New("internal server error")
	ErrUnsupportedType = errors.New("unsupported file type")
	ErrFileTooLarge    = errors.New("file exceeds maximum allowed size")
)
EOF

log "Domain done"

# =============================================================================
# 3. CLOUDINARY CLIENT (shared/pkg/cloudinary)
# =============================================================================
info "Writing Cloudinary client in shared/pkg..."

mkdir -p shared/pkg/cloudinary

cat > shared/pkg/cloudinary/client.go << 'EOF'
package cloudinary

import (
	"context"
	"fmt"
	"mime/multipart"

	"github.com/cloudinary/cloudinary-go/v2"
	"github.com/cloudinary/cloudinary-go/v2/api/uploader"
)

type Config struct {
	CloudName string
	APIKey    string
	APISecret string
	Folder    string // e.g. "ecocomply/inspections"
}

type UploadResult struct {
	PublicID string
	URL      string
	Bytes    int64
	Format   string
}

type Client struct {
	cld    *cloudinary.Cloudinary
	folder string
}

func NewClient(cfg Config) (*Client, error) {
	cld, err := cloudinary.NewFromParams(cfg.CloudName, cfg.APIKey, cfg.APISecret)
	if err != nil {
		return nil, fmt.Errorf("cloudinary init failed: %w", err)
	}
	return &Client{cld: cld, folder: cfg.Folder}, nil
}

// UploadFile uploads a multipart file to Cloudinary and returns the result.
func (c *Client) UploadFile(ctx context.Context, file multipart.File, filename string) (*UploadResult, error) {
	params := uploader.UploadParams{
		Folder:   c.folder,
		PublicID: filename,
	}

	result, err := c.cld.Upload.Upload(ctx, file, params)
	if err != nil {
		return nil, fmt.Errorf("cloudinary upload failed: %w", err)
	}

	return &UploadResult{
		PublicID: result.PublicID,
		URL:      result.SecureURL,
		Bytes:    int64(result.Bytes),
		Format:   result.Format,
	}, nil
}

// DeleteFile removes a file from Cloudinary by its public ID.
func (c *Client) DeleteFile(ctx context.Context, publicID string) error {
	_, err := c.cld.Upload.Destroy(ctx, uploader.DestroyParams{
		PublicID: publicID,
	})
	return err
}
EOF

log "Cloudinary client done"

# =============================================================================
# 4. DTOs
# =============================================================================
info "Writing DTOs..."

cat > "${BASE}/internal/dto/request/media_request.go" << 'EOF'
package request

// UploadMediaRequest is sent as multipart/form-data.
// File is handled separately via c.FormFile("file").
type UploadMediaRequest struct {
	InspectionID string   `form:"inspection_id" binding:"required,uuid"`
	CapturedVia  string   `form:"captured_via"  binding:"required,oneof=camera gallery"`
	Latitude     *float64 `form:"latitude"      binding:"omitempty"`
	Longitude    *float64 `form:"longitude"     binding:"omitempty"`
	GPSSource    string   `form:"gps_source"    binding:"omitempty,oneof=device manual none"`
	CapturedAt   string   `form:"captured_at"   binding:"omitempty"` // RFC3339
}
EOF

cat > "${BASE}/internal/dto/response/media_response.go" << 'EOF'
package response

import "time"

type MediaResponse struct {
	ID           string     `json:"id"`
	InspectionID string     `json:"inspection_id"`
	UploadedBy   string     `json:"uploaded_by"`
	URL          string     `json:"url"`
	Filename     string     `json:"filename"`
	MimeType     string     `json:"mime_type"`
	SizeBytes    int64      `json:"size_bytes"`
	CapturedVia  string     `json:"captured_via"`
	Latitude     *float64   `json:"latitude,omitempty"`
	Longitude    *float64   `json:"longitude,omitempty"`
	GPSSource    string     `json:"gps_source"`
	CapturedAt   time.Time  `json:"captured_at"`
	CreatedAt    time.Time  `json:"created_at"`
}

type MediaListResponse struct {
	Media []MediaResponse `json:"media"`
	Total int64           `json:"total"`
}
EOF

log "DTOs done"

# =============================================================================
# 5. REPOSITORY
# =============================================================================
info "Writing repository..."

cat > "${BASE}/internal/repository/interface/media_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/media-service/internal/domain"
	"github.com/google/uuid"
)

type MediaRepository interface {
	Create(ctx context.Context, media *domain.Media) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Media, error)
	FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Media, int64, error)
	SoftDelete(ctx context.Context, id uuid.UUID) error
}
EOF

cat > "${BASE}/internal/repository/postgres/media_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/media-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type mediaRepository struct {
	db *gorm.DB
}

func NewMediaRepository(db *gorm.DB) *mediaRepository {
	return &mediaRepository{db: db}
}

func (r *mediaRepository) Create(ctx context.Context, media *domain.Media) error {
	return r.db.WithContext(ctx).Create(media).Error
}

func (r *mediaRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Media, error) {
	var media domain.Media
	result := r.db.WithContext(ctx).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&media)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &media, result.Error
}

func (r *mediaRepository) FindByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.Media, int64, error) {
	var media []domain.Media
	var total int64

	r.db.WithContext(ctx).Model(&domain.Media{}).
		Where("inspection_id = ? AND deleted_at IS NULL", inspectionID).
		Count(&total)

	result := r.db.WithContext(ctx).
		Where("inspection_id = ? AND deleted_at IS NULL", inspectionID).
		Order("captured_at DESC").
		Find(&media)

	return media, total, result.Error
}

func (r *mediaRepository) SoftDelete(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).
		Model(&domain.Media{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}
EOF

log "Repository done"

# =============================================================================
# 6. SERVICE LAYER
# =============================================================================
info "Writing service layer..."

cat > "${BASE}/internal/service/media_service.go" << 'EOF'
package service

import (
	"context"
	"fmt"
	"mime/multipart"
	"path/filepath"
	"strings"
	"time"

	"github.com/ecocomply/media-service/internal/domain"
	"github.com/ecocomply/media-service/internal/dto/request"
	"github.com/ecocomply/media-service/internal/dto/response"
	irepository "github.com/ecocomply/media-service/internal/repository/interface"
	"github.com/ecocomply/shared/pkg/cloudinary"
	"github.com/google/uuid"
)

const (
	maxFileSizeBytes = 10 * 1024 * 1024 // 10MB
)

var allowedMimeTypes = map[string]bool{
	"image/jpeg": true,
	"image/png":  true,
	"image/webp": true,
	"image/heic": true,
}

type MediaService struct {
	mediaRepo  irepository.MediaRepository
	cloudinary *cloudinary.Client
}

func NewMediaService(mediaRepo irepository.MediaRepository, cloudinary *cloudinary.Client) *MediaService {
	return &MediaService{mediaRepo: mediaRepo, cloudinary: cloudinary}
}

// Upload validates, uploads to Cloudinary, and persists the media record.
func (s *MediaService) Upload(
	ctx context.Context,
	userID uuid.UUID,
	fileHeader *multipart.FileHeader,
	req request.UploadMediaRequest,
) (*response.MediaResponse, error) {

	// 1. Validate file size
	if fileHeader.Size > maxFileSizeBytes {
		return nil, domain.ErrFileTooLarge
	}

	// 2. Validate mime type
	mimeType := fileHeader.Header.Get("Content-Type")
	if !allowedMimeTypes[mimeType] {
		return nil, domain.ErrUnsupportedType
	}

	// 3. Parse inspection ID
	inspectionID, err := uuid.Parse(req.InspectionID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}

	// 4. Open file
	file, err := fileHeader.Open()
	if err != nil {
		return nil, fmt.Errorf("failed to open file: %w", err)
	}
	defer file.Close()

	// 5. Build a unique Cloudinary filename
	ext := filepath.Ext(fileHeader.Filename)
	cloudinaryFilename := fmt.Sprintf("%s_%s%s", inspectionID, uuid.New().String(), ext)

	// 6. Upload to Cloudinary
	result, err := s.cloudinary.UploadFile(ctx, file, cloudinaryFilename)
	if err != nil {
		return nil, err
	}

	// 7. Resolve GPS provenance
	gpsSource := domain.GPSNone
	captureSource := domain.CaptureSource(req.CapturedVia)

	var lat, lng *float64
	if captureSource == domain.SourceCamera && req.Latitude != nil && req.Longitude != nil {
		// Camera capture — GPS from device
		lat = req.Latitude
		lng = req.Longitude
		gpsSource = domain.GPSDevice
	} else if req.GPSSource == string(domain.GPSManual) && req.Latitude != nil && req.Longitude != nil {
		// Manual override provided
		lat = req.Latitude
		lng = req.Longitude
		gpsSource = domain.GPSManual
	}
	// Gallery uploads: GPS stays nil, gpsSource stays "none"

	// 8. Parse captured_at (default to now)
	capturedAt := time.Now()
	if req.CapturedAt != "" {
		if t, err := time.Parse(time.RFC3339, req.CapturedAt); err == nil {
			capturedAt = t
		}
	}

	// 9. Persist media record
	media := &domain.Media{
		InspectionID: inspectionID,
		UploadedBy:   userID,
		CloudinaryID: result.PublicID,
		URL:          result.URL,
		Filename:     strings.TrimSuffix(cloudinaryFilename, ext),
		MimeType:     mimeType,
		SizeBytes:    fileHeader.Size,
		CapturedVia:  captureSource,
		Latitude:     lat,
		Longitude:    lng,
		GPSSource:    gpsSource,
		CapturedAt:   capturedAt,
	}

	if err := s.mediaRepo.Create(ctx, media); err != nil {
		// Rollback Cloudinary upload on DB failure
		_ = s.cloudinary.DeleteFile(ctx, result.PublicID)
		return nil, err
	}

	res := toMediaResponse(media)
	return &res, nil
}

// GetByInspection returns all media for an inspection.
func (s *MediaService) GetByInspection(ctx context.Context, inspectionID uuid.UUID) (*response.MediaListResponse, error) {
	mediaList, total, err := s.mediaRepo.FindByInspection(ctx, inspectionID)
	if err != nil {
		return nil, err
	}

	var items []response.MediaResponse
	for _, m := range mediaList {
		items = append(items, toMediaResponse(&m))
	}

	return &response.MediaListResponse{Media: items, Total: total}, nil
}

// Delete soft-deletes a media record and removes it from Cloudinary.
func (s *MediaService) Delete(ctx context.Context, id uuid.UUID) error {
	media, err := s.mediaRepo.FindByID(ctx, id)
	if err != nil {
		return err
	}

	// Remove from Cloudinary first
	_ = s.cloudinary.DeleteFile(ctx, media.CloudinaryID)

	return s.mediaRepo.SoftDelete(ctx, id)
}

// --- mapper ---

func toMediaResponse(m *domain.Media) response.MediaResponse {
	return response.MediaResponse{
		ID:           m.ID.String(),
		InspectionID: m.InspectionID.String(),
		UploadedBy:   m.UploadedBy.String(),
		URL:          m.URL,
		Filename:     m.Filename,
		MimeType:     m.MimeType,
		SizeBytes:    m.SizeBytes,
		CapturedVia:  string(m.CapturedVia),
		Latitude:     m.Latitude,
		Longitude:    m.Longitude,
		GPSSource:    string(m.GPSSource),
		CapturedAt:   m.CapturedAt,
		CreatedAt:    m.CreatedAt,
	}
}
EOF

log "Service layer done"

# =============================================================================
# 7. HANDLER
# =============================================================================
info "Writing handler..."

cat > "${BASE}/internal/handler/media_handler.go" << 'EOF'
package handler

import (
	"github.com/ecocomply/media-service/internal/domain"
	"github.com/ecocomply/media-service/internal/dto/request"
	"github.com/ecocomply/media-service/internal/handler/middleware"
	"github.com/ecocomply/media-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type MediaHandler struct {
	svc *service.MediaService
}

func NewMediaHandler(svc *service.MediaService) *MediaHandler {
	return &MediaHandler{svc: svc}
}

// POST /api/v1/media  (multipart/form-data)
func (h *MediaHandler) Upload(c *gin.Context) {
	var req request.UploadMediaRequest
	if err := c.ShouldBind(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	fileHeader, err := c.FormFile("file")
	if err != nil {
		response.BadRequest(c, "file is required")
		return
	}

	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.Upload(c.Request.Context(), userID, fileHeader, req)
	if err != nil {
		handleError(c, err)
		return
	}

	response.Created(c, "media uploaded", res)
}

// GET /api/v1/media?inspection_id=xxx
func (h *MediaHandler) GetByInspection(c *gin.Context) {
	inspectionIDStr := c.Query("inspection_id")
	if inspectionIDStr == "" {
		response.BadRequest(c, "inspection_id is required")
		return
	}

	inspectionID, err := uuid.Parse(inspectionIDStr)
	if err != nil {
		response.BadRequest(c, "invalid inspection_id")
		return
	}

	res, err := h.svc.GetByInspection(c.Request.Context(), inspectionID)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}

	response.OK(c, "media retrieved", res)
}

// DELETE /api/v1/media/:id
func (h *MediaHandler) Delete(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid media id")
		return
	}

	if err := h.svc.Delete(c.Request.Context(), id); err != nil {
		handleError(c, err)
		return
	}

	response.OK(c, "media deleted", nil)
}

func handleError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput, domain.ErrUnsupportedType:
		response.BadRequest(c, err.Error())
	case domain.ErrFileTooLarge:
		c.JSON(413, gin.H{"success": false, "error": err.Error()})
	default:
		response.InternalError(c, "something went wrong")
	}
}
EOF

log "Handler done"

# =============================================================================
# 8. ROUTER
# =============================================================================
info "Writing router..."

cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"github.com/ecocomply/media-service/internal/di"
	"github.com/ecocomply/media-service/internal/handler"
	"github.com/ecocomply/media-service/internal/handler/middleware"
	"github.com/gin-gonic/gin"
)

func New(c *di.Container) *gin.Engine {
	if c.Config.Env == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())
	r.Use(middleware.CORS())

	// Increase max multipart memory to 20MB
	r.MaxMultipartMemory = 20 << 20

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "media-service"})
	})

	h := handler.NewMediaHandler(c.MediaService)

	v1 := r.Group("/api/v1/media")
	v1.Use(middleware.Auth(c.JWTManager))
	v1.Use(middleware.Tenant(c.DB))
	{
		v1.POST("", h.Upload)
		v1.GET("", h.GetByInspection)
		v1.DELETE("/:id", h.Delete)
	}

	return r
}
EOF

log "Router done"

# =============================================================================
# 9. DI / WIRE
# =============================================================================
info "Writing DI container..."

cat > "${BASE}/internal/di/wire.go" << 'EOF'
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
	mediaSvc  := service.NewMediaService(mediaRepo, cloudinaryClient)

	return &Container{
		Config:       cfg,
		DB:           db,
		Redis:        rdb,
		JWTManager:   jwtManager,
		MediaRepo:    mediaRepo,
		MediaService: mediaSvc,
	}, nil
}
EOF

log "DI container done"

# =============================================================================
# 10. CONFIG (add Cloudinary fields)
# =============================================================================
info "Writing config..."

cat > "${BASE}/internal/config/config.go" << 'EOF'
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env                 string
	Port                string
	GRPCPort            string
	DBHost              string
	DBPort              string
	DBName              string
	DBUser              string
	DBPassword          string
	RedisHost           string
	RedisPort           string
	RedisPass           string
	JWTSecret           string
	JWTExpiryHrs        int
	CloudinaryCloudName string
	CloudinaryAPIKey    string
	CloudinaryAPISecret string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env:                 getEnv("ENV", "development"),
		Port:                getEnv("PORT", "8083"),
		GRPCPort:            getEnv("GRPC_PORT", "50053"),
		DBHost:              getEnv("DB_HOST", "localhost"),
		DBPort:              getEnv("DB_PORT", "5432"),
		DBName:              getEnv("DB_NAME", "ecocomply"),
		DBUser:              getEnv("DB_USER", "postgres"),
		DBPassword:          getEnv("DB_PASSWORD", "secret"),
		RedisHost:           getEnv("REDIS_HOST", "localhost"),
		RedisPort:           getEnv("REDIS_PORT", "6379"),
		RedisPass:           getEnv("REDIS_PASS", ""),
		JWTSecret:           getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs:        expiry,
		CloudinaryCloudName: getEnv("CLOUDINARY_CLOUD_NAME", ""),
		CloudinaryAPIKey:    getEnv("CLOUDINARY_API_KEY", ""),
		CloudinaryAPISecret: getEnv("CLOUDINARY_API_SECRET", ""),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF

# =============================================================================
# 11. .env.example
# =============================================================================
cat > "${BASE}/.env.example" << 'EOF'
ENV=development
PORT=8083
GRPC_PORT=50053

DB_HOST=localhost
DB_PORT=5432
DB_NAME=ecocomply
DB_USER=postgres
DB_PASSWORD=secret

REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASS=

JWT_SECRET=change-me
JWT_EXPIRY_HOURS=24

CLOUDINARY_CLOUD_NAME=your_cloud_name
CLOUDINARY_API_KEY=your_api_key
CLOUDINARY_API_SECRET=your_api_secret
EOF

# =============================================================================
# 12. go.mod
# =============================================================================
info "Writing go.mod..."

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/media-service

go 1.22

require (
	github.com/cloudinary/cloudinary-go/v2 v2.7.0
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	github.com/stretchr/testify v1.9.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

# Also update shared/go.mod to include cloudinary
cat > shared/go.mod << 'EOF'
module github.com/ecocomply/shared

go 1.22

require (
	github.com/cloudinary/cloudinary-go/v2 v2.7.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)
EOF

log "go.mod done"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  media-service build complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Files written:"
find "${BASE}" -type f | sort | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "  1. cd shared && go mod tidy"
echo "  2. cd ${BASE} && go mod tidy"
echo "  3. go build ./..."
echo ""
