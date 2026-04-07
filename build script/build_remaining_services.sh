#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — collaboration, notification, export services build script
# Run from inside ~/ecocomply-ng:
#   chmod +x build_remaining_services.sh && ./build_remaining_services.sh
# =============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# ██████████████████████████████████████████████████████████
#  COLLABORATION SERVICE
# ██████████████████████████████████████████████████████████
# =============================================================================

BASE="services/collaboration-service"
info "Building ${BASE}..."

# --- Migrations ---
cat > "${BASE}/migrations/tenant/000001_create_collab.up.sql" << 'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS collab_sessions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID        NOT NULL UNIQUE,
    created_by      UUID        NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS collab_participants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (session_id, user_id)
);

CREATE TABLE IF NOT EXISTS collab_events (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id         UUID        NOT NULL,
    event_type      TEXT        NOT NULL,
    payload         JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_collab_sessions_inspection ON collab_sessions (inspection_id);
CREATE INDEX IF NOT EXISTS idx_collab_events_session      ON collab_events (session_id);
CREATE INDEX IF NOT EXISTS idx_collab_events_created      ON collab_events (created_at DESC);
EOF

cat > "${BASE}/migrations/tenant/000001_create_collab.down.sql" << 'EOF'
DROP TABLE IF EXISTS collab_events;
DROP TABLE IF EXISTS collab_participants;
DROP TABLE IF EXISTS collab_sessions;
EOF

# --- Domain ---
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
}

func (CollabSession) TableName() string { return "collab_sessions" }

type CollabParticipant struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	SessionID uuid.UUID `gorm:"type:uuid;not null"`
	UserID    uuid.UUID `gorm:"type:uuid;not null"`
	JoinedAt  time.Time `gorm:"not null"`
}

func (CollabParticipant) TableName() string { return "collab_participants" }

type CollabEvent struct {
	ID        uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	SessionID uuid.UUID  `gorm:"type:uuid;not null"`
	UserID    uuid.UUID  `gorm:"type:uuid;not null"`
	EventType string     `gorm:"not null"`
	Payload   []byte     `gorm:"type:jsonb"`
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
)

type WSEvent struct {
	Type    EventType   `json:"type"`
	Payload interface{} `json:"payload"`
	UserID  string      `json:"user_id"`
	OrgID   string      `json:"org_id"`
}
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound     = errors.New("record not found")
	ErrUnauthorized = errors.New("unauthorized")
	ErrForbidden    = errors.New("forbidden")
)
EOF

# --- WebSocket Hub ---
cat > "${BASE}/internal/ws/hub.go" << 'EOF'
package ws

import (
	"sync"
	"github.com/rs/zerolog/log"
)

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
			log.Info().Str("room", client.RoomID).Str("user", client.UserID).Msg("ws: client joined")

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
			log.Info().Str("room", client.RoomID).Str("user", client.UserID).Msg("ws: client left")

		case msg := <-h.message:
			h.mu.RLock()
			for client := range h.rooms[msg.RoomID] {
				if client != msg.Sender {
					select {
					case client.send <- msg.Payload:
					default:
						close(client.send)
						delete(h.rooms[msg.RoomID], client)
					}
				}
			}
			h.mu.RUnlock()
		}
	}
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

type Client struct {
	RoomID string
	UserID string
	hub    *Hub
	conn   *websocket.Conn
	send   chan []byte
}

func NewClient(hub *Hub, conn *websocket.Conn, roomID, userID string) *Client {
	return &Client{
		RoomID: roomID,
		UserID: userID,
		hub:    hub,
		conn:   conn,
		send:   make(chan []byte, 256),
	}
}

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
				log.Warn().Err(err).Str("user", c.UserID).Msg("ws: unexpected close")
			}
			break
		}
		c.hub.Broadcast(&Message{RoomID: c.RoomID, Payload: message, Sender: c})
	}
}

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

# --- Handler ---
cat > "${BASE}/internal/handler/collab_handler.go" << 'EOF'
package handler

import (
	"net/http"

	"github.com/ecocomply/collaboration-service/internal/handler/middleware"
	"github.com/ecocomply/collaboration-service/internal/ws"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // TODO: restrict origins in production
	},
}

type CollabHandler struct {
	hub *ws.Hub
}

func NewCollabHandler(hub *ws.Hub) *CollabHandler {
	return &CollabHandler{hub: hub}
}

// GET /api/v1/collaborate/:inspection_id/ws
func (h *CollabHandler) ServeWS(c *gin.Context) {
	inspectionID := c.Param("inspection_id")
	userID := c.GetString(middleware.ContextUserID)

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		response.InternalError(c, "websocket upgrade failed")
		return
	}

	client := ws.NewClient(h.hub, conn, inspectionID, userID)
	h.hub.Join(client)

	go client.WritePump()
	go client.ReadPump()
}
EOF

# --- Router ---
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

	h := handler.NewCollabHandler(c.Hub)

	v1 := r.Group("/api/v1/collaborate")
	v1.Use(middleware.Auth(c.JWTManager))
	{
		v1.GET("/:inspection_id/ws", h.ServeWS)
	}

	return r
}
EOF

# --- DI ---
cat > "${BASE}/internal/di/wire.go" << 'EOF'
package di

import (
	"fmt"

	"github.com/ecocomply/collaboration-service/internal/config"
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

	return &Container{
		Config: cfg, DB: db, Redis: rdb,
		JWTManager: jwtManager, Hub: hub,
	}, nil
}
EOF

# --- go.mod ---
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
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "collaboration-service done"

# =============================================================================
# ██████████████████████████████████████████████████████████
#  NOTIFICATION SERVICE
# ██████████████████████████████████████████████████████████
# =============================================================================

BASE="services/notification-service"
info "Building ${BASE}..."

# --- Migrations ---
cat > "${BASE}/migrations/tenant/000001_create_notifications.up.sql" << 'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE notification_status AS ENUM ('pending', 'sent', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS notifications (
    id           UUID                  PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id UUID                  NOT NULL,
    type         TEXT                  NOT NULL,
    subject      TEXT                  NOT NULL,
    body         TEXT                  NOT NULL,
    status       notification_status   NOT NULL DEFAULT 'pending',
    sent_at      TIMESTAMPTZ,
    error        TEXT,
    created_at   TIMESTAMPTZ           NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON notifications (recipient_id);
CREATE INDEX IF NOT EXISTS idx_notifications_status    ON notifications (status);
CREATE INDEX IF NOT EXISTS idx_notifications_created   ON notifications (created_at DESC);
EOF

cat > "${BASE}/migrations/tenant/000001_create_notifications.down.sql" << 'EOF'
DROP TABLE IF EXISTS notifications;
DROP TYPE  IF EXISTS notification_status;
EOF

# --- Domain ---
cat > "${BASE}/internal/domain/notification.go" << 'EOF'
package domain

import (
	"time"
	"github.com/google/uuid"
)

type NotificationStatus string

const (
	StatusPending NotificationStatus = "pending"
	StatusSent    NotificationStatus = "sent"
	StatusFailed  NotificationStatus = "failed"
)

type NotificationType string

const (
	TypeInvite          NotificationType = "invite"
	TypeDeadlineReminder NotificationType = "deadline_reminder"
	TypeReportShare     NotificationType = "report_share"
	TypeActionOverdue   NotificationType = "action_overdue"
	TypeStatusChanged   NotificationType = "status_changed"
)

type Notification struct {
	ID          uuid.UUID          `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	RecipientID uuid.UUID          `gorm:"type:uuid;not null"`
	Type        NotificationType   `gorm:"not null"`
	Subject     string             `gorm:"not null"`
	Body        string             `gorm:"not null"`
	Status      NotificationStatus `gorm:"type:notification_status;not null;default:pending"`
	SentAt      *time.Time
	Error       string
	CreatedAt   time.Time
}

func (Notification) TableName() string { return "notifications" }
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound     = errors.New("record not found")
	ErrInvalidInput = errors.New("invalid input")
)
EOF

# --- Email templates ---
mkdir -p "${BASE}/internal/email/templates"

cat > "${BASE}/internal/email/templates/invite.html" << 'EOF'
<!DOCTYPE html>
<html>
<body style="font-family:Arial,sans-serif;color:#1a1a1a;max-width:600px;margin:0 auto;padding:32px">
  <div style="border-bottom:3px solid #2e7d32;padding-bottom:16px;margin-bottom:24px">
    <h2 style="color:#2e7d32;margin:0">EcoComply NG</h2>
  </div>
  <h3>You've been invited</h3>
  <p>Hi {{.Name}},</p>
  <p>You have been invited to join <strong>{{.OrgName}}</strong> on EcoComply NG as a <strong>{{.Role}}</strong>.</p>
  <p>Your temporary password is: <code style="background:#f5f5f5;padding:4px 8px;border-radius:4px">{{.TempPassword}}</code></p>
  <p>Please log in and change your password immediately.</p>
  <a href="{{.LoginURL}}" style="display:inline-block;background:#2e7d32;color:#fff;padding:10px 24px;border-radius:4px;text-decoration:none;margin-top:16px">Log In</a>
  <p style="margin-top:32px;font-size:12px;color:#999">EcoComply NG · Environmental Compliance Platform</p>
</body>
</html>
EOF

cat > "${BASE}/internal/email/templates/deadline_reminder.html" << 'EOF'
<!DOCTYPE html>
<html>
<body style="font-family:Arial,sans-serif;color:#1a1a1a;max-width:600px;margin:0 auto;padding:32px">
  <div style="border-bottom:3px solid #e65100;padding-bottom:16px;margin-bottom:24px">
    <h2 style="color:#e65100;margin:0">Action Due Soon</h2>
  </div>
  <p>Hi {{.Name}},</p>
  <p>A remediation action assigned to you is due on <strong>{{.DueDate}}</strong>.</p>
  <p><strong>Action:</strong> {{.ActionDescription}}</p>
  <p><strong>Inspection:</strong> {{.ProjectName}}</p>
  <p>Please upload your evidence before the deadline.</p>
  <a href="{{.ActionURL}}" style="display:inline-block;background:#e65100;color:#fff;padding:10px 24px;border-radius:4px;text-decoration:none;margin-top:16px">View Action</a>
  <p style="margin-top:32px;font-size:12px;color:#999">EcoComply NG · Environmental Compliance Platform</p>
</body>
</html>
EOF

cat > "${BASE}/internal/email/templates/report_share.html" << 'EOF'
<!DOCTYPE html>
<html>
<body style="font-family:Arial,sans-serif;color:#1a1a1a;max-width:600px;margin:0 auto;padding:32px">
  <div style="border-bottom:3px solid #2e7d32;padding-bottom:16px;margin-bottom:24px">
    <h2 style="color:#2e7d32;margin:0">Inspection Report Shared</h2>
  </div>
  <p>Hi,</p>
  <p>An inspection report for <strong>{{.ProjectName}}</strong> has been shared with you.</p>
  <p>This link expires on <strong>{{.ExpiryDate}}</strong>.</p>
  <a href="{{.ShareURL}}" style="display:inline-block;background:#2e7d32;color:#fff;padding:10px 24px;border-radius:4px;text-decoration:none;margin-top:16px">View Report</a>
  <p style="margin-top:32px;font-size:12px;color:#999">EcoComply NG · Environmental Compliance Platform</p>
</body>
</html>
EOF

# --- Email sender ---
cat > "${BASE}/internal/email/sender.go" << 'EOF'
package email

import (
	"bytes"
	"fmt"
	"html/template"
	"net/smtp"
	"path/filepath"
)

type Config struct {
	SMTPHost     string
	SMTPPort     string
	SMTPUser     string
	SMTPPassword string
	FromAddress  string
	TemplatePath string
}

type Sender struct {
	cfg Config
}

func NewSender(cfg Config) *Sender {
	return &Sender{cfg: cfg}
}

func (s *Sender) Send(to, subject, templateName string, data interface{}) error {
	body, err := s.renderTemplate(templateName, data)
	if err != nil {
		return fmt.Errorf("template render: %w", err)
	}

	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n%s",
		s.cfg.FromAddress, to, subject, body,
	)

	addr := fmt.Sprintf("%s:%s", s.cfg.SMTPHost, s.cfg.SMTPPort)
	auth := smtp.PlainAuth("", s.cfg.SMTPUser, s.cfg.SMTPPassword, s.cfg.SMTPHost)

	return smtp.SendMail(addr, auth, s.cfg.FromAddress, []string{to}, []byte(msg))
}

func (s *Sender) renderTemplate(name string, data interface{}) (string, error) {
	path := filepath.Join(s.cfg.TemplatePath, name)
	tmpl, err := template.ParseFiles(path)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}
EOF

# --- DTOs ---
cat > "${BASE}/internal/dto/request/notification_request.go" << 'EOF'
package request

type SendNotificationRequest struct {
	RecipientID string `json:"recipient_id" binding:"required,uuid"`
	Type        string `json:"type"         binding:"required"`
	Subject     string `json:"subject"      binding:"required"`
	Body        string `json:"body"         binding:"required"`
}
EOF

cat > "${BASE}/internal/dto/response/notification_response.go" << 'EOF'
package response

import "time"

type NotificationResponse struct {
	ID          string     `json:"id"`
	RecipientID string     `json:"recipient_id"`
	Type        string     `json:"type"`
	Subject     string     `json:"subject"`
	Status      string     `json:"status"`
	SentAt      *time.Time `json:"sent_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}
EOF

# --- Repository ---
cat > "${BASE}/internal/repository/interface/notification_repository.go" << 'EOF'
package irepository

import (
	"context"
	"github.com/ecocomply/notification-service/internal/domain"
	"github.com/google/uuid"
)

type NotificationRepository interface {
	Create(ctx context.Context, n *domain.Notification) error
	Update(ctx context.Context, n *domain.Notification) error
	FindByRecipient(ctx context.Context, recipientID uuid.UUID, limit, offset int) ([]domain.Notification, int64, error)
}
EOF

cat > "${BASE}/internal/repository/postgres/notification_repo.go" << 'EOF'
package postgres

import (
	"context"

	"github.com/ecocomply/notification-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type notificationRepository struct{ db *gorm.DB }

func NewNotificationRepository(db *gorm.DB) *notificationRepository {
	return &notificationRepository{db: db}
}

func (r *notificationRepository) Create(ctx context.Context, n *domain.Notification) error {
	return r.db.WithContext(ctx).Create(n).Error
}

func (r *notificationRepository) Update(ctx context.Context, n *domain.Notification) error {
	return r.db.WithContext(ctx).Save(n).Error
}

func (r *notificationRepository) FindByRecipient(ctx context.Context, recipientID uuid.UUID, limit, offset int) ([]domain.Notification, int64, error) {
	var notifications []domain.Notification
	var total int64
	r.db.WithContext(ctx).Model(&domain.Notification{}).Where("recipient_id = ?", recipientID).Count(&total)
	result := r.db.WithContext(ctx).
		Where("recipient_id = ?", recipientID).
		Order("created_at DESC").
		Limit(limit).Offset(offset).
		Find(&notifications)
	return notifications, total, result.Error
}
EOF

# --- Service ---
cat > "${BASE}/internal/service/notification_service.go" << 'EOF'
package service

import (
	"context"
	"time"

	"github.com/ecocomply/notification-service/internal/domain"
	"github.com/ecocomply/notification-service/internal/dto/request"
	"github.com/ecocomply/notification-service/internal/dto/response"
	"github.com/ecocomply/notification-service/internal/email"
	irepository "github.com/ecocomply/notification-service/internal/repository/interface"
	"github.com/google/uuid"
)

type NotificationService struct {
	repo   irepository.NotificationRepository
	sender *email.Sender
}

func NewNotificationService(repo irepository.NotificationRepository, sender *email.Sender) *NotificationService {
	return &NotificationService{repo: repo, sender: sender}
}

func (s *NotificationService) Send(ctx context.Context, recipientEmail string, req request.SendNotificationRequest) (*response.NotificationResponse, error) {
	recipientID, err := uuid.Parse(req.RecipientID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}

	n := &domain.Notification{
		RecipientID: recipientID,
		Type:        domain.NotificationType(req.Type),
		Subject:     req.Subject,
		Body:        req.Body,
		Status:      domain.StatusPending,
	}

	if err := s.repo.Create(ctx, n); err != nil {
		return nil, err
	}

	// Send async
	go func() {
		err := s.sender.Send(recipientEmail, req.Subject, "report_share.html", map[string]string{
			"Body": req.Body,
		})
		bgCtx := context.Background()
		if err != nil {
			n.Status = domain.StatusFailed
			n.Error = err.Error()
		} else {
			n.Status = domain.StatusSent
			now := time.Now()
			n.SentAt = &now
		}
		_ = s.repo.Update(bgCtx, n)
	}()

	res := toResponse(n)
	return &res, nil
}

func (s *NotificationService) GetByRecipient(ctx context.Context, recipientID uuid.UUID, limit, offset int) ([]response.NotificationResponse, int64, error) {
	notifications, total, err := s.repo.FindByRecipient(ctx, recipientID, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	var res []response.NotificationResponse
	for _, n := range notifications {
		res = append(res, toResponse(&n))
	}
	return res, total, nil
}

func toResponse(n *domain.Notification) response.NotificationResponse {
	return response.NotificationResponse{
		ID:          n.ID.String(),
		RecipientID: n.RecipientID.String(),
		Type:        string(n.Type),
		Subject:     n.Subject,
		Status:      string(n.Status),
		SentAt:      n.SentAt,
		CreatedAt:   n.CreatedAt,
	}
}
EOF

# --- Handler ---
cat > "${BASE}/internal/handler/notification_handler.go" << 'EOF'
package handler

import (
	"github.com/ecocomply/notification-service/internal/handler/middleware"
	"github.com/ecocomply/notification-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type NotificationHandler struct {
	svc *service.NotificationService
}

func NewNotificationHandler(svc *service.NotificationService) *NotificationHandler {
	return &NotificationHandler{svc: svc}
}

// GET /api/v1/notifications
func (h *NotificationHandler) List(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, total, err := h.svc.GetByRecipient(c.Request.Context(), userID, 20, 0)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "notifications retrieved", gin.H{"notifications": res, "total": total})
}
EOF

# --- Router ---
cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"github.com/ecocomply/notification-service/internal/di"
	"github.com/ecocomply/notification-service/internal/handler"
	"github.com/ecocomply/notification-service/internal/handler/middleware"
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
		ctx.JSON(200, gin.H{"status": "ok", "service": "notification-service"})
	})

	h := handler.NewNotificationHandler(c.NotificationService)
	v1 := r.Group("/api/v1/notifications")
	v1.Use(middleware.Auth(c.JWTManager))
	v1.Use(middleware.Tenant(c.DB))
	{
		v1.GET("", h.List)
	}
	return r
}
EOF

# --- DI ---
cat > "${BASE}/internal/di/wire.go" << 'EOF'
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
	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)
	sender := email.NewSender(email.Config{
		SMTPHost:     cfg.SMTPHost,
		SMTPPort:     cfg.SMTPPort,
		SMTPUser:     cfg.SMTPUser,
		SMTPPassword: cfg.SMTPPassword,
		FromAddress:  cfg.FromAddress,
		TemplatePath: cfg.TemplatePath,
	})
	notificationRepo := postgres.NewNotificationRepository(db)
	notificationSvc  := service.NewNotificationService(notificationRepo, sender)

	return &Container{
		Config: cfg, DB: db, Redis: rdb,
		JWTManager:          jwtManager,
		NotificationRepo:    notificationRepo,
		NotificationService: notificationSvc,
	}, nil
}
EOF

# --- Config ---
cat > "${BASE}/internal/config/config.go" << 'EOF'
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env          string
	Port         string
	GRPCPort     string
	DBHost       string
	DBPort       string
	DBName       string
	DBUser       string
	DBPassword   string
	RedisHost    string
	RedisPort    string
	RedisPass    string
	JWTSecret    string
	JWTExpiryHrs int
	SMTPHost     string
	SMTPPort     string
	SMTPUser     string
	SMTPPassword string
	FromAddress  string
	TemplatePath string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env: getEnv("ENV", "development"), Port: getEnv("PORT", "8086"),
		GRPCPort: getEnv("GRPC_PORT", "50056"),
		DBHost: getEnv("DB_HOST", "localhost"), DBPort: getEnv("DB_PORT", "5432"),
		DBName: getEnv("DB_NAME", "ecocomply"), DBUser: getEnv("DB_USER", "postgres"),
		DBPassword:   getEnv("DB_PASSWORD", "secret"),
		RedisHost:    getEnv("REDIS_HOST", "localhost"),
		RedisPort:    getEnv("REDIS_PORT", "6379"),
		RedisPass:    getEnv("REDIS_PASS", ""),
		JWTSecret:    getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs: expiry,
		SMTPHost:     getEnv("SMTP_HOST", "smtp.gmail.com"),
		SMTPPort:     getEnv("SMTP_PORT", "587"),
		SMTPUser:     getEnv("SMTP_USER", ""),
		SMTPPassword: getEnv("SMTP_PASSWORD", ""),
		FromAddress:  getEnv("FROM_ADDRESS", "noreply@ecocomply.ng"),
		TemplatePath: getEnv("TEMPLATE_PATH", "./internal/email/templates"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF

cat > "${BASE}/.env.example" << 'EOF'
ENV=development
PORT=8086
GRPC_PORT=50056

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

SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your@gmail.com
SMTP_PASSWORD=your_app_password
FROM_ADDRESS=noreply@ecocomply.ng
TEMPLATE_PATH=./internal/email/templates
EOF

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/notification-service

go 1.22

require (
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "notification-service done"

# =============================================================================
# ██████████████████████████████████████████████████████████
#  EXPORT SERVICE
# ██████████████████████████████████████████████████████████
# =============================================================================

BASE="services/export-service"
info "Building ${BASE}..."

# --- Migrations ---
cat > "${BASE}/migrations/tenant/000001_create_export_jobs.up.sql" << 'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE export_job_status AS ENUM ('queued', 'running', 'done', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE export_job_type AS ENUM ('db_backup', 'report_batch', 'media_export');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS export_jobs (
    id          UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    type        export_job_type     NOT NULL,
    status      export_job_status   NOT NULL DEFAULT 'queued',
    file_url    TEXT,
    error       TEXT,
    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_by  UUID                NOT NULL,
    created_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_export_jobs_status     ON export_jobs (status);
CREATE INDEX IF NOT EXISTS idx_export_jobs_created_by ON export_jobs (created_by);
EOF

cat > "${BASE}/migrations/tenant/000001_create_export_jobs.down.sql" << 'EOF'
DROP TABLE IF EXISTS export_jobs;
DROP TYPE  IF EXISTS export_job_type;
DROP TYPE  IF EXISTS export_job_status;
EOF

# --- Domain ---
cat > "${BASE}/internal/domain/export_job.go" << 'EOF'
package domain

import (
	"time"
	"github.com/google/uuid"
)

type ExportJobStatus string
type ExportJobType string

const (
	JobQueued  ExportJobStatus = "queued"
	JobRunning ExportJobStatus = "running"
	JobDone    ExportJobStatus = "done"
	JobFailed  ExportJobStatus = "failed"

	TypeDBBackup     ExportJobType = "db_backup"
	TypeReportBatch  ExportJobType = "report_batch"
	TypeMediaExport  ExportJobType = "media_export"
)

type ExportJob struct {
	ID         uuid.UUID       `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Type       ExportJobType   `gorm:"type:export_job_type;not null"`
	Status     ExportJobStatus `gorm:"type:export_job_status;not null;default:queued"`
	FileURL    string
	Error      string
	StartedAt  *time.Time
	FinishedAt *time.Time
	CreatedBy  uuid.UUID       `gorm:"type:uuid;not null"`
	CreatedAt  time.Time
}

func (ExportJob) TableName() string { return "export_jobs" }
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound     = errors.New("record not found")
	ErrUnauthorized = errors.New("unauthorized")
	ErrForbidden    = errors.New("forbidden")
)
EOF

# --- Backup ---
mkdir -p "${BASE}/internal/backup"

cat > "${BASE}/internal/backup/db_backup.go" << 'EOF'
package backup

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"
)

type DBBackup struct {
	Host     string
	Port     string
	User     string
	Password string
	DBName   string
	OutDir   string
}

// Run executes pg_dump and writes a compressed backup file.
// Returns the output file path.
func (b *DBBackup) Run(ctx context.Context) (string, error) {
	if err := os.MkdirAll(b.OutDir, 0755); err != nil {
		return "", fmt.Errorf("backup dir: %w", err)
	}

	filename := fmt.Sprintf("%s/backup_%s.sql.gz", b.OutDir, time.Now().Format("20060102_150405"))

	cmd := exec.CommandContext(ctx,
		"sh", "-c",
		fmt.Sprintf("PGPASSWORD=%s pg_dump -h %s -p %s -U %s %s | gzip > %s",
			b.Password, b.Host, b.Port, b.User, b.DBName, filename),
	)

	if output, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("pg_dump failed: %s — %w", string(output), err)
	}

	return filename, nil
}
EOF

# --- DTOs ---
cat > "${BASE}/internal/dto/request/export_request.go" << 'EOF'
package request

type CreateExportJobRequest struct {
	Type string `json:"type" binding:"required,oneof=db_backup report_batch media_export"`
}
EOF

cat > "${BASE}/internal/dto/response/export_response.go" << 'EOF'
package response

import "time"

type ExportJobResponse struct {
	ID         string     `json:"id"`
	Type       string     `json:"type"`
	Status     string     `json:"status"`
	FileURL    string     `json:"file_url,omitempty"`
	Error      string     `json:"error,omitempty"`
	StartedAt  *time.Time `json:"started_at,omitempty"`
	FinishedAt *time.Time `json:"finished_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}
EOF

# --- Repository ---
cat > "${BASE}/internal/repository/interface/export_repository.go" << 'EOF'
package irepository

import (
	"context"
	"github.com/ecocomply/export-service/internal/domain"
	"github.com/google/uuid"
)

type ExportRepository interface {
	Create(ctx context.Context, job *domain.ExportJob) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.ExportJob, error)
	Update(ctx context.Context, job *domain.ExportJob) error
	List(ctx context.Context, limit, offset int) ([]domain.ExportJob, int64, error)
}
EOF

cat > "${BASE}/internal/repository/postgres/export_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/export-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type exportRepository struct{ db *gorm.DB }

func NewExportRepository(db *gorm.DB) *exportRepository {
	return &exportRepository{db: db}
}

func (r *exportRepository) Create(ctx context.Context, job *domain.ExportJob) error {
	return r.db.WithContext(ctx).Create(job).Error
}

func (r *exportRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.ExportJob, error) {
	var job domain.ExportJob
	result := r.db.WithContext(ctx).Where("id = ?", id).First(&job)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &job, result.Error
}

func (r *exportRepository) Update(ctx context.Context, job *domain.ExportJob) error {
	return r.db.WithContext(ctx).Save(job).Error
}

func (r *exportRepository) List(ctx context.Context, limit, offset int) ([]domain.ExportJob, int64, error) {
	var jobs []domain.ExportJob
	var total int64
	r.db.WithContext(ctx).Model(&domain.ExportJob{}).Count(&total)
	result := r.db.WithContext(ctx).Order("created_at DESC").Limit(limit).Offset(offset).Find(&jobs)
	return jobs, total, result.Error
}
EOF

# --- Service ---
cat > "${BASE}/internal/service/export_service.go" << 'EOF'
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/ecocomply/export-service/internal/backup"
	"github.com/ecocomply/export-service/internal/domain"
	"github.com/ecocomply/export-service/internal/dto/request"
	"github.com/ecocomply/export-service/internal/dto/response"
	irepository "github.com/ecocomply/export-service/internal/repository/interface"
	"github.com/google/uuid"
)

type ExportService struct {
	repo     irepository.ExportRepository
	dbBackup *backup.DBBackup
}

func NewExportService(repo irepository.ExportRepository, dbBackup *backup.DBBackup) *ExportService {
	return &ExportService{repo: repo, dbBackup: dbBackup}
}

func (s *ExportService) CreateJob(ctx context.Context, userID uuid.UUID, req request.CreateExportJobRequest) (*response.ExportJobResponse, error) {
	job := &domain.ExportJob{
		Type:      domain.ExportJobType(req.Type),
		Status:    domain.JobQueued,
		CreatedBy: userID,
	}
	if err := s.repo.Create(ctx, job); err != nil {
		return nil, err
	}

	go s.runJob(job.ID)

	res := toResponse(job)
	return &res, nil
}

func (s *ExportService) List(ctx context.Context, limit, offset int) ([]response.ExportJobResponse, int64, error) {
	jobs, total, err := s.repo.List(ctx, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	var res []response.ExportJobResponse
	for _, j := range jobs {
		res = append(res, toResponse(&j))
	}
	return res, total, nil
}

func (s *ExportService) runJob(jobID uuid.UUID) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	job, err := s.repo.FindByID(ctx, jobID)
	if err != nil {
		return
	}

	now := time.Now()
	job.Status = domain.JobRunning
	job.StartedAt = &now
	_ = s.repo.Update(ctx, job)

	var fileURL string
	var runErr error

	switch job.Type {
	case domain.TypeDBBackup:
		fileURL, runErr = s.dbBackup.Run(ctx)
	default:
		runErr = fmt.Errorf("job type %s not yet implemented", job.Type)
	}

	finished := time.Now()
	job.FinishedAt = &finished

	if runErr != nil {
		job.Status = domain.JobFailed
		job.Error = runErr.Error()
	} else {
		job.Status = domain.JobDone
		job.FileURL = fileURL
	}

	_ = s.repo.Update(ctx, job)
}

func toResponse(j *domain.ExportJob) response.ExportJobResponse {
	return response.ExportJobResponse{
		ID:         j.ID.String(),
		Type:       string(j.Type),
		Status:     string(j.Status),
		FileURL:    j.FileURL,
		Error:      j.Error,
		StartedAt:  j.StartedAt,
		FinishedAt: j.FinishedAt,
		CreatedAt:  j.CreatedAt,
	}
}
EOF

# --- Handler ---
cat > "${BASE}/internal/handler/export_handler.go" << 'EOF'
package handler

import (
	"github.com/ecocomply/export-service/internal/dto/request"
	"github.com/ecocomply/export-service/internal/handler/middleware"
	"github.com/ecocomply/export-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type ExportHandler struct {
	svc *service.ExportService
}

func NewExportHandler(svc *service.ExportService) *ExportHandler {
	return &ExportHandler{svc: svc}
}

// POST /api/v1/exports
func (h *ExportHandler) CreateJob(c *gin.Context) {
	var req request.CreateExportJobRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.CreateJob(c.Request.Context(), userID, req)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.Created(c, "export job queued", res)
}

// GET /api/v1/exports
func (h *ExportHandler) List(c *gin.Context) {
	res, total, err := h.svc.List(c.Request.Context(), 20, 0)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "export jobs retrieved", gin.H{"jobs": res, "total": total})
}
EOF

# --- Router ---
cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"github.com/ecocomply/export-service/internal/di"
	"github.com/ecocomply/export-service/internal/handler"
	"github.com/ecocomply/export-service/internal/handler/middleware"
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
		ctx.JSON(200, gin.H{"status": "ok", "service": "export-service"})
	})

	h := handler.NewExportHandler(c.ExportService)
	v1 := r.Group("/api/v1/exports")
	v1.Use(middleware.Auth(c.JWTManager))
	v1.Use(middleware.Tenant(c.DB))
	v1.Use(middleware.RequireRole("org_admin", "manager"))
	{
		v1.POST("", h.CreateJob)
		v1.GET("", h.List)
	}
	return r
}
EOF

# --- DI ---
cat > "${BASE}/internal/di/wire.go" << 'EOF'
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
	dbBackup := &backup.DBBackup{
		Host: cfg.DBHost, Port: cfg.DBPort,
		User: cfg.DBUser, Password: cfg.DBPassword,
		DBName: cfg.DBName, OutDir: cfg.BackupDir,
	}
	exportRepo := postgres.NewExportRepository(db)
	exportSvc  := service.NewExportService(exportRepo, dbBackup)

	return &Container{
		Config: cfg, DB: db, Redis: rdb,
		JWTManager:    jwtManager,
		ExportRepo:    exportRepo,
		ExportService: exportSvc,
	}, nil
}
EOF

# --- Config ---
cat > "${BASE}/internal/config/config.go" << 'EOF'
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env          string
	Port         string
	GRPCPort     string
	DBHost       string
	DBPort       string
	DBName       string
	DBUser       string
	DBPassword   string
	RedisHost    string
	RedisPort    string
	RedisPass    string
	JWTSecret    string
	JWTExpiryHrs int
	BackupDir    string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env: getEnv("ENV", "development"), Port: getEnv("PORT", "8087"),
		GRPCPort:   getEnv("GRPC_PORT", "50057"),
		DBHost:     getEnv("DB_HOST", "localhost"),
		DBPort:     getEnv("DB_PORT", "5432"),
		DBName:     getEnv("DB_NAME", "ecocomply"),
		DBUser:     getEnv("DB_USER", "postgres"),
		DBPassword: getEnv("DB_PASSWORD", "secret"),
		RedisHost:  getEnv("REDIS_HOST", "localhost"),
		RedisPort:  getEnv("REDIS_PORT", "6379"),
		RedisPass:  getEnv("REDIS_PASS", ""),
		JWTSecret:  getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs: expiry,
		BackupDir:  getEnv("BACKUP_DIR", "/tmp/backups"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF

cat > "${BASE}/.env.example" << 'EOF'
ENV=development
PORT=8087
GRPC_PORT=50057

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

BACKUP_DIR=/tmp/backups
EOF

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/export-service

go 1.22

require (
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "export-service done"

# =============================================================================
# COLLABORATION go.mod config
# =============================================================================
BASE="services/collaboration-service"
cat > "${BASE}/internal/config/config.go" << 'EOF'
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env          string
	Port         string
	GRPCPort     string
	DBHost       string
	DBPort       string
	DBName       string
	DBUser       string
	DBPassword   string
	RedisHost    string
	RedisPort    string
	RedisPass    string
	JWTSecret    string
	JWTExpiryHrs int
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env: getEnv("ENV", "development"), Port: getEnv("PORT", "8085"),
		GRPCPort:     getEnv("GRPC_PORT", "50055"),
		DBHost:       getEnv("DB_HOST", "localhost"),
		DBPort:       getEnv("DB_PORT", "5432"),
		DBName:       getEnv("DB_NAME", "ecocomply"),
		DBUser:       getEnv("DB_USER", "postgres"),
		DBPassword:   getEnv("DB_PASSWORD", "secret"),
		RedisHost:    getEnv("REDIS_HOST", "localhost"),
		RedisPort:    getEnv("REDIS_PORT", "6379"),
		RedisPass:    getEnv("REDIS_PASS", ""),
		JWTSecret:    getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs: expiry,
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF

cat > "${BASE}/.env.example" << 'EOF'
ENV=development
PORT=8085
GRPC_PORT=50055

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
EOF

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  All remaining services built!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Now run go mod tidy + go build for each:"
echo ""
echo "  cd services/collaboration-service && go mod tidy && go build ./..."
echo "  cd ../../notification-service     && go mod tidy && go build ./..."
echo "  cd ../../export-service           && go mod tidy && go build ./..."
echo ""
