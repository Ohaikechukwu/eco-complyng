#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Fix collaboration-service compile errors
# Run from ~/ecocomply-ng:
#   chmod +x fix_collaboration_service.sh && ./fix_collaboration_service.sh
# =============================================================================

BASE="services/collaboration-service"

GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[✔]${NC} $1"; }

# Fix 1: Add ErrInvalidInput to domain/errors.go
cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound     = errors.New("record not found")
	ErrUnauthorized = errors.New("unauthorized")
	ErrForbidden    = errors.New("forbidden")
	ErrInvalidInput = errors.New("invalid input")
)
EOF
log "domain/errors.go fixed"

# Fix 2: Rewrite collab_service.go — fixes payload type and removes Participants field reference
cat > "${BASE}/internal/service/collab_service.go" << 'EOF'
package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/ecocomply/collaboration-service/internal/domain"
	irepository "github.com/ecocomply/collaboration-service/internal/repository/interface"
	"github.com/google/uuid"
)

type CollabService struct {
	sessionRepo irepository.SessionRepository
}

func NewCollabService(sessionRepo irepository.SessionRepository) *CollabService {
	return &CollabService{sessionRepo: sessionRepo}
}

// GetOrCreateSession returns an existing active session for an inspection
// or creates a new one.
func (s *CollabService) GetOrCreateSession(ctx context.Context, inspectionID, userID uuid.UUID) (*domain.CollabSession, error) {
	session, err := s.sessionRepo.FindByInspection(ctx, inspectionID)
	if err == nil && session.IsActive {
		return session, nil
	}

	session = &domain.CollabSession{
		InspectionID: inspectionID,
		CreatedBy:    userID,
		IsActive:     true,
	}
	if err := s.sessionRepo.Create(ctx, session); err != nil {
		return nil, err
	}
	return session, nil
}

// RecordEvent persists a WebSocket event to the collab_events table.
func (s *CollabService) RecordEvent(ctx context.Context, sessionID, userID uuid.UUID, eventType domain.EventType, payload interface{}) error {
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return domain.ErrInvalidInput
	}

	event := &domain.CollabEvent{
		SessionID: sessionID,
		UserID:    userID,
		EventType: string(eventType),
		Payload:   payloadBytes,
		CreatedAt: time.Now(),
	}
	return s.sessionRepo.CreateEvent(ctx, event)
}

// AddParticipant records a user joining a session.
func (s *CollabService) AddParticipant(ctx context.Context, sessionID, userID uuid.UUID) error {
	participant := &domain.CollabParticipant{
		SessionID: sessionID,
		UserID:    userID,
		JoinedAt:  time.Now(),
	}
	return s.sessionRepo.AddParticipant(ctx, participant)
}

// RemoveParticipant records a user leaving a session.
func (s *CollabService) RemoveParticipant(ctx context.Context, sessionID, userID uuid.UUID) error {
	return s.sessionRepo.RemoveParticipant(ctx, sessionID, userID)
}
EOF
log "service/collab_service.go fixed"

# Fix 3: Add session repository interface
mkdir -p "${BASE}/internal/repository/interface"
cat > "${BASE}/internal/repository/interface/session_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
)

type SessionRepository interface {
	Create(ctx context.Context, session *domain.CollabSession) error
	FindByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error)
	AddParticipant(ctx context.Context, p *domain.CollabParticipant) error
	RemoveParticipant(ctx context.Context, sessionID, userID uuid.UUID) error
	CreateEvent(ctx context.Context, event *domain.CollabEvent) error
}
EOF
log "repository/interface/session_repository.go created"

# Fix 4: Add postgres implementation
mkdir -p "${BASE}/internal/repository/postgres"
cat > "${BASE}/internal/repository/postgres/session_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type sessionRepository struct{ db *gorm.DB }

func NewSessionRepository(db *gorm.DB) *sessionRepository {
	return &sessionRepository{db: db}
}

func (r *sessionRepository) Create(ctx context.Context, session *domain.CollabSession) error {
	return r.db.WithContext(ctx).Create(session).Error
}

func (r *sessionRepository) FindByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error) {
	var session domain.CollabSession
	result := r.db.WithContext(ctx).
		Where("inspection_id = ? AND is_active = true", inspectionID).
		First(&session)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &session, result.Error
}

func (r *sessionRepository) AddParticipant(ctx context.Context, p *domain.CollabParticipant) error {
	return r.db.WithContext(ctx).
		Where(domain.CollabParticipant{SessionID: p.SessionID, UserID: p.UserID}).
		FirstOrCreate(p).Error
}

func (r *sessionRepository) RemoveParticipant(ctx context.Context, sessionID, userID uuid.UUID) error {
	return r.db.WithContext(ctx).
		Where("session_id = ? AND user_id = ?", sessionID, userID).
		Delete(&domain.CollabParticipant{}).Error
}

func (r *sessionRepository) CreateEvent(ctx context.Context, event *domain.CollabEvent) error {
	return r.db.WithContext(ctx).Create(event).Error
}
EOF
log "repository/postgres/session_repo.go created"

# Fix 5: Update DI to wire the session repo and service
cat > "${BASE}/internal/di/wire.go" << 'EOF'
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
	Config         *config.Config
	DB             *gorm.DB
	Redis          *redis.Client
	JWTManager     *sharedjwt.Manager
	Hub            *ws.Hub
	SessionRepo    irepository.SessionRepository
	CollabService  *service.CollabService
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

	sessionRepo  := postgres.NewSessionRepository(db)
	collabSvc    := service.NewCollabService(sessionRepo)

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
EOF
log "di/wire.go updated"

echo ""
echo -e "${GREEN}All fixes applied.${NC}"
echo ""
echo "Now run:"
echo "  cd services/collaboration-service && go mod tidy && go build ./..."
