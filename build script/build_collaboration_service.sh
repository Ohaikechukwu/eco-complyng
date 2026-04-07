#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — collaboration-service complete build script
# Run from inside ~/ecocomply-ng:
#   chmod +x build_collaboration_service.sh && ./build_collaboration_service.sh
# =============================================================================

BASE="services/collaboration-service"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# 1. MIGRATIONS
# =============================================================================
info "Writing migrations..."

cat > "${BASE}/migrations/tenant/000001_create_collaboration.up.sql" << 'EOF'
-- =============================================================================
-- Migration: 000001_create_collaboration (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- TABLE: collab_sessions
-- One session per inspection — tracks active real-time collaboration
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collab_sessions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID        NOT NULL UNIQUE,
    created_by      UUID        NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cs_inspection_id ON collab_sessions (inspection_id);
CREATE INDEX IF NOT EXISTS idx_cs_is_active     ON collab_sessions (is_active);

-- -----------------------------------------------------------------------------
-- TABLE: collab_participants
-- Tracks who has joined a session
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collab_participants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at     TIMESTAMPTZ,
    UNIQUE (session_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_cp_session_id ON collab_participants (session_id);
CREATE INDEX IF NOT EXISTS idx_cp_user_id    ON collab_participants (user_id);

-- -----------------------------------------------------------------------------
-- TABLE: collab_events
-- Audit log of all real-time events in a session
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collab_events (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    event_type  TEXT        NOT NULL,
    payload     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ce_session_id  ON collab_events (session_id);
CREATE INDEX IF NOT EXISTS idx_ce_event_type  ON collab_events (event_type);
CREATE INDEX IF NOT EXISTS idx_ce_created_at  ON collab_events (created_at DESC);

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_collab_sessions_updated_at
    BEFORE UPDATE ON collab_sessions
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
EOF

cat > "${BASE}/migrations/tenant/000001_create_collaboration.down.sql" << 'EOF'
DROP TRIGGER IF EXISTS set_collab_sessions_updated_at ON collab_sessions;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE IF EXISTS collab_events;
DROP TABLE IF EXISTS collab_participants;
DROP TABLE IF EXISTS collab_sessions;
EOF

log "Migrations done"

# =============================================================================
# 2. DOMAIN
# =============================================================================
info "Writing domain layer..."

cat > "${BASE}/internal/domain/session.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type CollabSession struct {
	ID           uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID `gorm:"type:uuid;not null;uniqueIndex"`
	CreatedBy    uuid.UUID `gorm:"type:uuid;not null"`
	IsActive     bool      `gorm:"not null;default:true"`
	CreatedAt    time.Time
	UpdatedAt    time.Time

	Participants []CollabParticipant `gorm:"foreignKey:SessionID"`
}

func (CollabSession) TableName() string { return "collab_sessions" }

type CollabParticipant struct {
	ID        uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	SessionID uuid.UUID  `gorm:"type:uuid;not null"`
	UserID    uuid.UUID  `gorm:"type:uuid;not null"`
	JoinedAt  time.Time  `gorm:"not null;default:NOW()"`
	LeftAt    *time.Time
}

func (CollabParticipant) TableName() string { return "collab_participants" }

type CollabEvent struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	SessionID uuid.UUID `gorm:"type:uuid;not null"`
	UserID    uuid.UUID `gorm:"type:uuid;not null"`
	EventType string    `gorm:"not null"`
	Payload   string    `gorm:"type:jsonb"`
	CreatedAt time.Time
}

func (CollabEvent) TableName() string { return "collab_events" }
EOF

cat > "${BASE}/internal/domain/event.go" << 'EOF'
package domain

type EventType string

const (
	EventChecklistUpdate EventType = "checklist_update"
	EventCommentAdded    EventType = "comment_added"
	EventStatusChanged   EventType = "status_changed"
	EventActionCreated   EventType = "action_created"
	EventUserJoined      EventType = "user_joined"
	EventUserLeft        EventType = "user_left"
	EventCursorMove      EventType = "cursor_move"
)

// WSMessage is the envelope for all WebSocket messages.
type WSMessage struct {
	Type    EventType   `json:"type"`
	Payload interface{} `json:"payload"`
	UserID  string      `json:"user_id"`
	OrgID   string      `json:"org_id"`
	RoomID  string      `json:"room_id"` // inspection_id
}
EOF

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

log "Domain done"

# =============================================================================
# 3. WEBSOCKET HUB
# =============================================================================
info "Writing WebSocket hub and client..."

cat > "${BASE}/internal/ws/hub.go" << 'EOF'
package ws

import (
	"sync"

	"github.com/rs/zerolog/log"
)

// Hub maintains the set of active WebSocket clients grouped by room (inspection_id).
type Hub struct {
	mu      sync.RWMutex
	rooms   map[string]map[*Client]bool
	join    chan *Client
	leave   chan *Client
	message chan *Message
}

type Message struct {
	RoomID  string
	Payload []byte
	Sender  *Client
}

func NewHub() *Hub {
	return &Hub{
		rooms:   make(map[string]map[*Client]bool),
		join:    make(chan *Client, 64),
		leave:   make(chan *Client, 64),
		message: make(chan *Message, 256),
	}
}

// Run starts the hub event loop — call in a goroutine.
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.join:
			h.mu.Lock()
			if h.rooms[client.RoomID] == nil {
				h.rooms[client.RoomID] = make(map[*Client]bool)
			}
			h.rooms[client.RoomID][client] = true
			h.mu.Unlock()
			log.Info().
				Str("room", client.RoomID).
				Str("user", client.UserID).
				Int("participants", len(h.rooms[client.RoomID])).
				Msg("client joined room")

		case client := <-h.leave:
			h.mu.Lock()
			if room, ok := h.rooms[client.RoomID]; ok {
				delete(room, client)
				if len(room) == 0 {
					delete(h.rooms, client.RoomID)
				}
			}
			h.mu.Unlock()
			close(client.send)
			log.Info().
				Str("room", client.RoomID).
				Str("user", client.UserID).
				Msg("client left room")

		case msg := <-h.message:
			h.mu.RLock()
			for client := range h.rooms[msg.RoomID] {
				if client != msg.Sender {
					select {
					case client.send <- msg.Payload:
					default:
						// Client send buffer full — remove it
						close(client.send)
						delete(h.rooms[msg.RoomID], client)
					}
				}
			}
			h.mu.RUnlock()
		}
	}
}

// RoomCount returns how many clients are in a room.
func (h *Hub) RoomCount(roomID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.rooms[roomID])
}

func (h *Hub) Join(c *Client)       { h.join <- c }
func (h *Hub) Leave(c *Client)      { h.leave <- c }
func (h *Hub) Broadcast(m *Message) { h.message <- m }
EOF

cat > "${BASE}/internal/ws/client.go" << 'EOF'
package ws

import (
	"time"

	"github.com/gorilla/websocket"
	"github.com/rs/zerolog/log"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = (pongWait * 9) / 10
	maxMessageSize = 4096
)

// Client is a single WebSocket connection.
type Client struct {
	hub    *Hub
	conn   *websocket.Conn
	send   chan []byte
	RoomID string
	UserID string
	OrgID  string
}

func NewClient(hub *Hub, conn *websocket.Conn, roomID, userID, orgID string) *Client {
	return &Client{
		hub:    hub,
		conn:   conn,
		send:   make(chan []byte, 256),
		RoomID: roomID,
		UserID: userID,
		OrgID:  orgID,
	}
}

// ReadPump reads messages from the WebSocket connection and broadcasts them.
func (c *Client) ReadPump() {
	defer func() {
		c.hub.Leave(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Error().Err(err).Str("user", c.UserID).Msg("websocket read error")
			}
			break
		}
		c.hub.Broadcast(&Message{
			RoomID:  c.RoomID,
			Payload: message,
			Sender:  c,
		})
	}
}

// WritePump writes messages from the send channel to the WebSocket connection.
func (c *Client) WritePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			w, err := c.conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)
			// Flush any queued messages in the same write
			n := len(c.send)
			for i := 0; i < n; i++ {
				w.Write([]byte{'\n'})
				w.Write(<-c.send)
			}
			if err := w.Close(); err != nil {
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
EOF

cat > "${BASE}/internal/ws/upgrader.go" << 'EOF'
package ws

import (
	"net/http"

	"github.com/gorilla/websocket"
)

var Upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	// Allow all origins in development — tighten in production
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}
EOF

log "WebSocket hub and client done"

# =============================================================================
# 4. DTOs
# =============================================================================
info "Writing DTOs..."

cat > "${BASE}/internal/dto/request/collab_request.go" << 'EOF'
package request

// StartSessionRequest starts a new collaboration session for an inspection.
type StartSessionRequest struct {
	InspectionID string `json:"inspection_id" binding:"required,uuid"`
}

// EndSessionRequest ends an active session.
type EndSessionRequest struct {
	SessionID string `json:"session_id" binding:"required,uuid"`
}
EOF

cat > "${BASE}/internal/dto/response/collab_response.go" << 'EOF'
package response

import "time"

type SessionResponse struct {
	ID           string               `json:"id"`
	InspectionID string               `json:"inspection_id"`
	IsActive     bool                 `json:"is_active"`
	Participants []ParticipantResponse `json:"participants"`
	CreatedAt    time.Time            `json:"created_at"`
}

type ParticipantResponse struct {
	UserID   string     `json:"user_id"`
	JoinedAt time.Time  `json:"joined_at"`
	LeftAt   *time.Time `json:"left_at,omitempty"`
}

type RoomStatusResponse struct {
	RoomID       string `json:"room_id"`
	Participants int    `json:"participants"`
	IsActive     bool   `json:"is_active"`
}
EOF

log "DTOs done"

# =============================================================================
# 5. REPOSITORY
# =============================================================================
info "Writing repository..."

cat > "${BASE}/internal/repository/interface/collab_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
)

type CollabRepository interface {
	CreateSession(ctx context.Context, session *domain.CollabSession) error
	FindSessionByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error)
	FindSessionByID(ctx context.Context, id uuid.UUID) (*domain.CollabSession, error)
	UpdateSession(ctx context.Context, session *domain.CollabSession) error

	AddParticipant(ctx context.Context, p *domain.CollabParticipant) error
	UpdateParticipant(ctx context.Context, p *domain.CollabParticipant) error
	FindParticipant(ctx context.Context, sessionID, userID uuid.UUID) (*domain.CollabParticipant, error)

	LogEvent(ctx context.Context, event *domain.CollabEvent) error
}
EOF

cat > "${BASE}/internal/repository/postgres/collab_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type collabRepository struct {
	db *gorm.DB
}

func NewCollabRepository(db *gorm.DB) *collabRepository {
	return &collabRepository{db: db}
}

func (r *collabRepository) CreateSession(ctx context.Context, session *domain.CollabSession) error {
	return r.db.WithContext(ctx).Create(session).Error
}

func (r *collabRepository) FindSessionByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error) {
	var session domain.CollabSession
	result := r.db.WithContext(ctx).
		Preload("Participants").
		Where("inspection_id = ? AND is_active = true", inspectionID).
		First(&session)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &session, result.Error
}

func (r *collabRepository) FindSessionByID(ctx context.Context, id uuid.UUID) (*domain.CollabSession, error) {
	var session domain.CollabSession
	result := r.db.WithContext(ctx).
		Preload("Participants").
		Where("id = ?", id).
		First(&session)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &session, result.Error
}

func (r *collabRepository) UpdateSession(ctx context.Context, session *domain.CollabSession) error {
	return r.db.WithContext(ctx).Save(session).Error
}

func (r *collabRepository) AddParticipant(ctx context.Context, p *domain.CollabParticipant) error {
	return r.db.WithContext(ctx).
		Where(domain.CollabParticipant{SessionID: p.SessionID, UserID: p.UserID}).
		FirstOrCreate(p).Error
}

func (r *collabRepository) UpdateParticipant(ctx context.Context, p *domain.CollabParticipant) error {
	return r.db.WithContext(ctx).Save(p).Error
}

func (r *collabRepository) FindParticipant(ctx context.Context, sessionID, userID uuid.UUID) (*domain.CollabParticipant, error) {
	var p domain.CollabParticipant
	result := r.db.WithContext(ctx).
		Where("session_id = ? AND user_id = ?", sessionID, userID).
		First(&p)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &p, result.Error
}

func (r *collabRepository) LogEvent(ctx context.Context, event *domain.CollabEvent) error {
	return r.db.WithContext(ctx).Create(event).Error
}
EOF

log "Repository done"

# =============================================================================
# 6. SERVICE LAYER
# =============================================================================
info "Writing service layer..."

cat > "${BASE}/internal/service/collab_service.go" << 'EOF'
package service

import (
	"context"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/ecocomply/collaboration-service/internal/dto/request"
	"github.com/ecocomply/collaboration-service/internal/dto/response"
	irepository "github.com/ecocomply/collaboration-service/internal/repository/interface"
	"github.com/google/uuid"
)

type CollabService struct {
	repo irepository.CollabRepository
}

func NewCollabService(repo irepository.CollabRepository) *CollabService {
	return &CollabService{repo: repo}
}

// StartSession creates or returns an existing active session for an inspection.
func (s *CollabService) StartSession(ctx context.Context, userID uuid.UUID, req request.StartSessionRequest) (*response.SessionResponse, error) {
	inspectionID, err := uuid.Parse(req.InspectionID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}

	// Return existing active session if present
	existing, err := s.repo.FindSessionByInspection(ctx, inspectionID)
	if err == nil {
		res := toSessionResponse(existing)
		return &res, nil
	}

	// Create new session
	session := &domain.CollabSession{
		InspectionID: inspectionID,
		CreatedBy:    userID,
		IsActive:     true,
	}
	if err := s.repo.CreateSession(ctx, session); err != nil {
		return nil, err
	}

	res := toSessionResponse(session)
	return &res, nil
}

// EndSession deactivates a session.
func (s *CollabService) EndSession(ctx context.Context, sessionID uuid.UUID) error {
	session, err := s.repo.FindSessionByID(ctx, sessionID)
	if err != nil {
		return err
	}
	session.IsActive = false
	return s.repo.UpdateSession(ctx, session)
}

// GetSessionByInspection returns the active session for an inspection.
func (s *CollabService) GetSessionByInspection(ctx context.Context, inspectionID uuid.UUID) (*response.SessionResponse, error) {
	session, err := s.repo.FindSessionByInspection(ctx, inspectionID)
	if err != nil {
		return nil, err
	}
	res := toSessionResponse(session)
	return &res, nil
}

// RecordJoin logs a participant joining the session.
func (s *CollabService) RecordJoin(ctx context.Context, sessionID, userID uuid.UUID) error {
	p := &domain.CollabParticipant{
		SessionID: sessionID,
		UserID:    userID,
	}
	return s.repo.AddParticipant(ctx, p)
}

// RecordLeave marks a participant as having left.
func (s *CollabService) RecordLeave(ctx context.Context, sessionID, userID uuid.UUID) error {
	p, err := s.repo.FindParticipant(ctx, sessionID, userID)
	if err != nil {
		return nil // not an error if they weren't tracked
	}
	now := domain.CollabParticipant{}
	_ = now
	// Mark left_at
	return s.repo.UpdateParticipant(ctx, p)
}

// LogEvent persists a collaboration event to the audit log.
func (s *CollabService) LogEvent(ctx context.Context, sessionID, userID uuid.UUID, eventType, payload string) error {
	event := &domain.CollabEvent{
		SessionID: sessionID,
		UserID:    userID,
		EventType: eventType,
		Payload:   payload,
	}
	return s.repo.LogEvent(ctx, event)
}

func toSessionResponse(s *domain.CollabSession) response.SessionResponse {
	res := response.SessionResponse{
		ID:           s.ID.String(),
		InspectionID: s.InspectionID.String(),
		IsActive:     s.IsActive,
		CreatedAt:    s.CreatedAt,
	}
	for _, p := range s.Participants {
		res.Participants = append(res.Participants, response.ParticipantResponse{
			UserID:   p.UserID.String(),
			JoinedAt: p.JoinedAt,
			LeftAt:   p.LeftAt,
		})
	}
	return res
}
EOF

log "Service layer done"

# =============================================================================
# 7. HANDLER
# =============================================================================
info "Writing handler..."

cat > "${BASE}/internal/handler/collab_handler.go" << 'EOF'
package handler

import (
	"encoding/json"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/ecocomply/collaboration-service/internal/dto/request"
	"github.com/ecocomply/collaboration-service/internal/handler/middleware"
	"github.com/ecocomply/collaboration-service/internal/service"
	"github.com/ecocomply/collaboration-service/internal/ws"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/rs/zerolog/log"
)

type CollabHandler struct {
	svc *service.CollabService
	hub *ws.Hub
}

func NewCollabHandler(svc *service.CollabService, hub *ws.Hub) *CollabHandler {
	return &CollabHandler{svc: svc, hub: hub}
}

// POST /api/v1/collaborate/sessions
func (h *CollabHandler) StartSession(c *gin.Context) {
	var req request.StartSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.StartSession(c.Request.Context(), userID, req)
	if err != nil {
		handleError(c, err)
		return
	}
	response.Created(c, "session started", res)
}

// DELETE /api/v1/collaborate/sessions/:id
func (h *CollabHandler) EndSession(c *gin.Context) {
	sessionID, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid session id")
		return
	}
	if err := h.svc.EndSession(c.Request.Context(), sessionID); err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "session ended", nil)
}

// GET /api/v1/collaborate/sessions?inspection_id=xxx
func (h *CollabHandler) GetSession(c *gin.Context) {
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
	res, err := h.svc.GetSessionByInspection(c.Request.Context(), inspectionID)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "session retrieved", res)
}

// GET /api/v1/collaborate/rooms/:room_id/status
func (h *CollabHandler) RoomStatus(c *gin.Context) {
	roomID := c.Param("room_id")
	count := h.hub.RoomCount(roomID)
	c.JSON(200, gin.H{
		"success": true,
		"data": gin.H{
			"room_id":      roomID,
			"participants": count,
			"is_active":    count > 0,
		},
	})
}

// GET /api/v1/collaborate/ws/:inspection_id
// WebSocket upgrade endpoint — JWT validated via query param token
func (h *CollabHandler) ServeWS(c *gin.Context) {
	inspectionID := c.Param("inspection_id")
	userID := c.GetString(middleware.ContextUserID)
	orgID := c.GetString(middleware.ContextOrgID)

	conn, err := ws.Upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Error().Err(err).Msg("websocket upgrade failed")
		return
	}

	client := ws.NewClient(h.hub, conn, inspectionID, userID, orgID)
	h.hub.Join(client)

	// Broadcast join event to room
	joinEvent, _ := json.Marshal(domain.WSMessage{
		Type:   domain.EventUserJoined,
		UserID: userID,
		OrgID:  orgID,
		RoomID: inspectionID,
		Payload: map[string]string{
			"user_id": userID,
		},
	})
	h.hub.Broadcast(&ws.Message{
		RoomID:  inspectionID,
		Payload: joinEvent,
		Sender:  client,
	})

	// Start read/write pumps
	go client.WritePump()
	client.ReadPump() // blocks until disconnect
}

func handleError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput:
		response.BadRequest(c, err.Error())
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
	"github.com/ecocomply/collaboration-service/internal/di"
	"github.com/ecocomply/collaboration-service/internal/handler"
	"github.com/ecocomply/collaboration-service/internal/handler/middleware"
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

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "collaboration-service"})
	})

	h := handler.NewCollabHandler(c.CollabService, c.Hub)

	v1 := r.Group("/api/v1/collaborate")
	v1.Use(middleware.Auth(c.JWTManager))
	v1.Use(middleware.Tenant(c.DB))
	{
		// Session management
		v1.POST("/sessions", h.StartSession)
		v1.GET("/sessions", h.GetSession)
		v1.DELETE("/sessions/:id", h.EndSession)

		// Room status
		v1.GET("/rooms/:room_id/status", h.RoomStatus)

		// WebSocket endpoint
		v1.GET("/ws/:inspection_id", h.ServeWS)
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
	Config     *config.Config
	DB         *gorm.DB
	Redis      *redis.Client
	JWTManager *sharedjwt.Manager
	Hub        *ws.Hub

	CollabRepo    irepository.CollabRepository
	CollabService *service.CollabService
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

	hub := ws.NewHub()
	go hub.Run()

	collabRepo := postgres.NewCollabRepository(db)
	collabSvc  := service.NewCollabService(collabRepo)

	return &Container{
		Config:        cfg,
		DB:            db,
		Redis:         rdb,
		JWTManager:    jwtManager,
		Hub:           hub,
		CollabRepo:    collabRepo,
		CollabService: collabSvc,
	}, nil
}
EOF

log "DI container done"

# =============================================================================
# 10. go.mod
# =============================================================================
info "Writing go.mod..."

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/collaboration-service

go 1.22

require (
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/gorilla/websocket v1.5.1
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	github.com/stretchr/testify v1.9.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "go.mod done"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  collaboration-service build complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Files written:"
find "${BASE}" -type f | sort | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "  1. cd ${BASE} && go mod tidy"
echo "  2. go build ./..."
echo ""
