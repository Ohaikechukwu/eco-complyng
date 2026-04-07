#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — api-gateway middleware + proxy fix
# Run from inside ~/ecocomply-ng:
#   chmod +x fix_api_gateway.sh && ./fix_api_gateway.sh
# =============================================================================

BASE="api-gateway"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

mkdir -p "${BASE}/internal/middleware"
mkdir -p "${BASE}/internal/proxy"
mkdir -p "${BASE}/internal/di"

# =============================================================================
# MIDDLEWARE
# =============================================================================
info "Writing middleware..."

# Logger
cat > "${BASE}/internal/middleware/logger.go" << 'EOF'
package middleware

import (
	"time"

	"github.com/gin-gonic/gin"
	"github.com/rs/zerolog/log"
)

func Logger() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		log.Info().
			Str("method", c.Request.Method).
			Str("path", c.Request.URL.Path).
			Str("service", resolveService(c.Request.URL.Path)).
			Int("status", c.Writer.Status()).
			Dur("latency", time.Since(start)).
			Str("ip", c.ClientIP()).
			Msg("gateway")
	}
}

func resolveService(path string) string {
	prefixes := map[string]string{
		"/api/v1/auth":          "auth-service",
		"/api/v1/inspections":   "inspection-service",
		"/api/v1/media":         "media-service",
		"/api/v1/reports":       "report-service",
		"/api/v1/collaborate":   "collaboration-service",
		"/api/v1/notifications": "notification-service",
		"/api/v1/exports":       "export-service",
	}
	for prefix, svc := range prefixes {
		if len(path) >= len(prefix) && path[:len(prefix)] == prefix {
			return svc
		}
	}
	return "unknown"
}
EOF

# CORS
cat > "${BASE}/internal/middleware/cors.go" << 'EOF'
package middleware

import (
	"github.com/gin-gonic/gin"
)

func CORS(allowedOrigins []string) gin.HandlerFunc {
	originSet := make(map[string]bool)
	for _, o := range allowedOrigins {
		originSet[o] = true
	}

	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")

		// Allow if origin is in the whitelist OR if no origins configured (dev mode)
		if len(allowedOrigins) == 0 || originSet[origin] {
			c.Header("Access-Control-Allow-Origin", origin)
		} else {
			c.Header("Access-Control-Allow-Origin", allowedOrigins[0])
		}

		c.Header("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Origin,Content-Type,Authorization,X-Requested-With")
		c.Header("Access-Control-Allow-Credentials", "true")
		c.Header("Access-Control-Max-Age", "86400")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	}
}
EOF

# Rate limiter
cat > "${BASE}/internal/middleware/rate_limit.go" << 'EOF'
package middleware

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

// RateLimit uses a Redis sliding window counter per IP.
// limit = max requests per window duration.
func RateLimit(rdb *redis.Client, limit int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()
		key := fmt.Sprintf("rate:%s", ip)

		ctx := context.Background()
		pipe := rdb.Pipeline()
		incr := pipe.Incr(ctx, key)
		pipe.Expire(ctx, key, window)
		pipe.Exec(ctx)

		count := incr.Val()
		if count > int64(limit) {
			c.JSON(http.StatusTooManyRequests, gin.H{
				"success": false,
				"error":   "too many requests — slow down",
			})
			c.Abort()
			return
		}

		c.Header("X-RateLimit-Limit", fmt.Sprintf("%d", limit))
		c.Header("X-RateLimit-Remaining", fmt.Sprintf("%d", int64(limit)-count))
		c.Next()
	}
}

// StrictRateLimit applies a tighter limit for sensitive routes (login, register).
func StrictRateLimit(rdb *redis.Client) gin.HandlerFunc {
	return RateLimit(rdb, 10, time.Minute) // 10 req/min per IP
}

// DefaultRateLimit applies a general limit for all other routes.
func DefaultRateLimit(rdb *redis.Client) gin.HandlerFunc {
	return RateLimit(rdb, 300, time.Minute) // 300 req/min per IP
}
EOF

# Auth middleware — validates JWT at gateway level before proxying
cat > "${BASE}/internal/middleware/auth.go" << 'EOF'
package middleware

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"
)

type GatewayClaims struct {
	UserID    string `json:"user_id"`
	OrgID     string `json:"org_id"`
	OrgSchema string `json:"org_schema"`
	Role      string `json:"role"`
	jwt.RegisteredClaims
}

// ValidateJWT validates the JWT and injects user context headers for downstream services.
// Downstream services trust these headers since they come from the gateway.
func ValidateJWT(secret string, rdb *redis.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token == "" {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "missing token"})
			c.Abort()
			return
		}

		claims, err := parseToken(token, secret)
		if err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "invalid or expired token"})
			c.Abort()
			return
		}

		// Check token blacklist in Redis
		blacklistKey := fmt.Sprintf("blacklist:%s", claims.ID)
		exists, _ := rdb.Exists(context.Background(), blacklistKey).Result()
		if exists > 0 {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "token has been revoked"})
			c.Abort()
			return
		}

		// Inject identity headers so downstream services don't re-validate JWT
		c.Request.Header.Set("X-User-ID", claims.UserID)
		c.Request.Header.Set("X-Org-ID", claims.OrgID)
		c.Request.Header.Set("X-Org-Schema", claims.OrgSchema)
		c.Request.Header.Set("X-User-Role", claims.Role)

		c.Next()
	}
}

// OptionalJWT validates the JWT only if present — used for public routes like share links.
func OptionalJWT(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token != "" {
			if claims, err := parseToken(token, secret); err == nil {
				c.Request.Header.Set("X-User-ID", claims.UserID)
				c.Request.Header.Set("X-Org-ID", claims.OrgID)
				c.Request.Header.Set("X-Org-Schema", claims.OrgSchema)
				c.Request.Header.Set("X-User-Role", claims.Role)
			}
		}
		c.Next()
	}
}

func parseToken(tokenStr, secret string) (*GatewayClaims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &GatewayClaims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return []byte(secret), nil
	})
	if err != nil || !token.Valid {
		return nil, fmt.Errorf("invalid token")
	}
	claims, ok := token.Claims.(*GatewayClaims)
	if !ok {
		return nil, fmt.Errorf("invalid claims")
	}
	if claims.ExpiresAt != nil && claims.ExpiresAt.Before(time.Now()) {
		return nil, fmt.Errorf("token expired")
	}
	return claims, nil
}

func extractToken(c *gin.Context) string {
	bearer := c.GetHeader("Authorization")
	if strings.HasPrefix(bearer, "Bearer ") {
		return strings.TrimPrefix(bearer, "Bearer ")
	}
	cookie, err := c.Cookie("access_token")
	if err == nil {
		return cookie
	}
	return ""
}
EOF

log "Middleware done"

# =============================================================================
# PROXY
# =============================================================================
info "Writing proxy handlers..."

# Base reverse proxy helper
cat > "${BASE}/internal/proxy/proxy.go" << 'EOF'
package proxy

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/rs/zerolog/log"
)

// New creates a reverse proxy handler for the given target URL.
// stripPrefix is the gateway prefix to strip before forwarding.
// e.g. /api/v1/auth/login → strip nothing → /api/v1/auth/login
func New(targetURL string) gin.HandlerFunc {
	target, err := url.Parse(targetURL)
	if err != nil {
		log.Fatal().Err(err).Str("target", targetURL).Msg("invalid proxy target")
	}

	rp := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = target.Scheme
			req.URL.Host = target.Host
			req.Host = target.Host
			// Forward the real client IP
			if clientIP := req.Header.Get("X-Forwarded-For"); clientIP == "" {
				req.Header.Set("X-Forwarded-For", req.RemoteAddr)
			}
		},
		Transport: &http.Transport{
			ResponseHeaderTimeout: 30 * time.Second,
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Error().Err(err).Str("target", targetURL).Msg("proxy error")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			w.Write([]byte(`{"success":false,"error":"service temporarily unavailable"}`))
		},
	}

	return func(c *gin.Context) {
		rp.ServeHTTP(c.Writer, c.Request)
	}
}
EOF

# Per-service proxy handlers
cat > "${BASE}/internal/proxy/auth.go" << 'EOF'
package proxy

import (
	"github.com/gin-gonic/gin"
)

type AuthProxy struct {
	handler gin.HandlerFunc
}

func NewAuthProxy(serviceURL string) *AuthProxy {
	return &AuthProxy{handler: New(serviceURL)}
}

func (p *AuthProxy) Handler() gin.HandlerFunc {
	return p.handler
}
EOF

cat > "${BASE}/internal/proxy/inspection.go" << 'EOF'
package proxy

import "github.com/gin-gonic/gin"

type InspectionProxy struct{ handler gin.HandlerFunc }

func NewInspectionProxy(serviceURL string) *InspectionProxy {
	return &InspectionProxy{handler: New(serviceURL)}
}

func (p *InspectionProxy) Handler() gin.HandlerFunc { return p.handler }
EOF

cat > "${BASE}/internal/proxy/media.go" << 'EOF'
package proxy

import "github.com/gin-gonic/gin"

type MediaProxy struct{ handler gin.HandlerFunc }

func NewMediaProxy(serviceURL string) *MediaProxy {
	return &MediaProxy{handler: New(serviceURL)}
}

func (p *MediaProxy) Handler() gin.HandlerFunc { return p.handler }
EOF

cat > "${BASE}/internal/proxy/report.go" << 'EOF'
package proxy

import "github.com/gin-gonic/gin"

type ReportProxy struct{ handler gin.HandlerFunc }

func NewReportProxy(serviceURL string) *ReportProxy {
	return &ReportProxy{handler: New(serviceURL)}
}

func (p *ReportProxy) Handler() gin.HandlerFunc { return p.handler }
EOF

cat > "${BASE}/internal/proxy/collaboration.go" << 'EOF'
package proxy

import "github.com/gin-gonic/gin"

type CollaborationProxy struct{ handler gin.HandlerFunc }

func NewCollaborationProxy(serviceURL string) *CollaborationProxy {
	return &CollaborationProxy{handler: New(serviceURL)}
}

func (p *CollaborationProxy) Handler() gin.HandlerFunc { return p.handler }
EOF

cat > "${BASE}/internal/proxy/notification.go" << 'EOF'
package proxy

import "github.com/gin-gonic/gin"

type NotificationProxy struct{ handler gin.HandlerFunc }

func NewNotificationProxy(serviceURL string) *NotificationProxy {
	return &NotificationProxy{handler: New(serviceURL)}
}

func (p *NotificationProxy) Handler() gin.HandlerFunc { return p.handler }
EOF

cat > "${BASE}/internal/proxy/export.go" << 'EOF'
package proxy

import "github.com/gin-gonic/gin"

type ExportProxy struct{ handler gin.HandlerFunc }

func NewExportProxy(serviceURL string) *ExportProxy {
	return &ExportProxy{handler: New(serviceURL)}
}

func (p *ExportProxy) Handler() gin.HandlerFunc { return p.handler }
EOF

log "Proxy handlers done"

# =============================================================================
# DI — wire the gateway container
# =============================================================================
info "Writing DI container..."

cat > "${BASE}/internal/di/wire.go" << 'EOF'
package di

import (
	"fmt"

	"github.com/ecocomply/api-gateway/internal/config"
	"github.com/ecocomply/api-gateway/internal/proxy"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	"github.com/redis/go-redis/v9"
)

type Container struct {
	Config *config.Config
	Redis  *redis.Client

	AuthProxy           *proxy.AuthProxy
	InspectionProxy     *proxy.InspectionProxy
	MediaProxy          *proxy.MediaProxy
	ReportProxy         *proxy.ReportProxy
	CollaborationProxy  *proxy.CollaborationProxy
	NotificationProxy   *proxy.NotificationProxy
	ExportProxy         *proxy.ExportProxy
}

func NewContainer(cfg *config.Config) (*Container, error) {
	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host:     cfg.RedisHost,
		Port:     cfg.RedisPort,
		Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}

	return &Container{
		Config:              cfg,
		Redis:               rdb,
		AuthProxy:           proxy.NewAuthProxy(cfg.AuthServiceURL),
		InspectionProxy:     proxy.NewInspectionProxy(cfg.InspectionServiceURL),
		MediaProxy:          proxy.NewMediaProxy(cfg.MediaServiceURL),
		ReportProxy:         proxy.NewReportProxy(cfg.ReportServiceURL),
		CollaborationProxy:  proxy.NewCollaborationProxy(cfg.CollaborationServiceURL),
		NotificationProxy:   proxy.NewNotificationProxy(cfg.NotificationServiceURL),
		ExportProxy:         proxy.NewExportProxy(cfg.ExportServiceURL),
	}, nil
}
EOF

log "DI container done"

# =============================================================================
# ROUTER — rewrite with proper middleware wiring
# =============================================================================
info "Rewriting router with full middleware..."

cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"strings"

	"github.com/ecocomply/api-gateway/internal/di"
	"github.com/ecocomply/api-gateway/internal/middleware"
	"github.com/gin-gonic/gin"
)

func New(c *di.Container) *gin.Engine {
	if c.Config.Env == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())
	r.Use(middleware.CORS(strings.Split(c.Config.AllowedOrigins, ",")))
	r.Use(middleware.DefaultRateLimit(c.Redis))

	// Health check
	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "api-gateway"})
	})

	v1 := r.Group("/api/v1")
	{
		// ── Auth — public routes (no JWT, strict rate limit) ──────────────────
		auth := v1.Group("/auth")
		auth.Use(middleware.StrictRateLimit(c.Redis))
		{
			// These routes are public — no JWT required
			auth.POST("/register",       c.AuthProxy.Handler())
			auth.POST("/login",          c.AuthProxy.Handler())
			auth.POST("/refresh",        c.AuthProxy.Handler())
			auth.POST("/forgot-password",c.AuthProxy.Handler())
			auth.POST("/reset-password", c.AuthProxy.Handler())

			// Protected auth routes
			authProtected := auth.Group("")
			authProtected.Use(middleware.ValidateJWT(c.Config.JWTSecret, c.Redis))
			{
				authProtected.POST("/logout",             c.AuthProxy.Handler())
				authProtected.GET("/profile",             c.AuthProxy.Handler())
				authProtected.PATCH("/profile",           c.AuthProxy.Handler())
				authProtected.PATCH("/profile/password",  c.AuthProxy.Handler())
				authProtected.GET("/users",               c.AuthProxy.Handler())
				authProtected.POST("/users/invite",       c.AuthProxy.Handler())
				authProtected.PATCH("/users/:id/role",    c.AuthProxy.Handler())
			}
		}

		// ── All other services — JWT required ─────────────────────────────────
		protected := v1.Group("")
		protected.Use(middleware.ValidateJWT(c.Config.JWTSecret, c.Redis))
		{
			// Inspections
			protected.Any("/inspections/*path", c.InspectionProxy.Handler())

			// Media
			protected.Any("/media/*path", c.MediaProxy.Handler())

			// Reports — public share endpoint does not need JWT
			protected.Any("/reports/*path", func(ctx *gin.Context) {
				path := ctx.Param("path")
				// /reports/share/:token is public — skip JWT
				if len(path) > 7 && path[:7] == "/share/" {
					middleware.OptionalJWT(c.Config.JWTSecret)(ctx)
				}
				c.ReportProxy.Handler()(ctx)
			})

			// Collaboration (WebSocket upgrade)
			protected.Any("/collaborate/*path", c.CollaborationProxy.Handler())

			// Notifications
			protected.Any("/notifications/*path", c.NotificationProxy.Handler())

			// Exports
			protected.Any("/exports/*path", c.ExportProxy.Handler())
		}
	}

	return r
}
EOF

log "Router rewritten"

# =============================================================================
# CONFIG — add AllowedOrigins + Redis fields
# =============================================================================
info "Updating config..."

cat > "${BASE}/internal/config/config.go" << 'EOF'
package config

import "os"

type Config struct {
	Env                     string
	Port                    string
	JWTSecret               string
	AllowedOrigins          string
	RedisHost               string
	RedisPort               string
	RedisPass               string
	AuthServiceURL          string
	InspectionServiceURL    string
	MediaServiceURL         string
	ReportServiceURL        string
	CollaborationServiceURL string
	NotificationServiceURL  string
	ExportServiceURL        string
}

func Load() *Config {
	return &Config{
		Env:                     getEnv("ENV", "development"),
		Port:                    getEnv("PORT", "8080"),
		JWTSecret:               getEnv("JWT_SECRET", "change-me"),
		AllowedOrigins:          getEnv("ALLOWED_ORIGINS", "http://localhost:3000"),
		RedisHost:               getEnv("REDIS_HOST", "localhost"),
		RedisPort:               getEnv("REDIS_PORT", "6379"),
		RedisPass:               getEnv("REDIS_PASS", ""),
		AuthServiceURL:          getEnv("AUTH_SERVICE_URL", "http://localhost:8081"),
		InspectionServiceURL:    getEnv("INSPECTION_SERVICE_URL", "http://localhost:8082"),
		MediaServiceURL:         getEnv("MEDIA_SERVICE_URL", "http://localhost:8083"),
		ReportServiceURL:        getEnv("REPORT_SERVICE_URL", "http://localhost:8084"),
		CollaborationServiceURL: getEnv("COLLABORATION_SERVICE_URL", "http://localhost:8085"),
		NotificationServiceURL:  getEnv("NOTIFICATION_SERVICE_URL", "http://localhost:8086"),
		ExportServiceURL:        getEnv("EXPORT_SERVICE_URL", "http://localhost:8087"),
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
# .env.example update
# =============================================================================
cat > "${BASE}/.env.example" << 'EOF'
ENV=development
PORT=8080
JWT_SECRET=change-me-to-a-secure-secret
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:3001

REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASS=

AUTH_SERVICE_URL=http://localhost:8081
INSPECTION_SERVICE_URL=http://localhost:8082
MEDIA_SERVICE_URL=http://localhost:8083
REPORT_SERVICE_URL=http://localhost:8084
COLLABORATION_SERVICE_URL=http://localhost:8085
NOTIFICATION_SERVICE_URL=http://localhost:8086
EXPORT_SERVICE_URL=http://localhost:8087
EOF

# =============================================================================
# CMD/MAIN — update to use DI container
# =============================================================================
info "Updating cmd/main.go..."

cat > "${BASE}/cmd/main.go" << 'EOF'
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ecocomply/api-gateway/internal/config"
	"github.com/ecocomply/api-gateway/internal/di"
	"github.com/ecocomply/api-gateway/internal/router"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

func main() {
	zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stdout})

	cfg := config.Load()

	container, err := di.NewContainer(cfg)
	if err != nil {
		log.Fatal().Err(err).Msg("failed to initialize gateway container")
	}

	r := router.New(container)

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.Port),
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Info().Str("port", cfg.Port).Msg("api-gateway starting")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal().Err(err).Msg("gateway error")
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	log.Info().Msg("api-gateway shutting down...")
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatal().Err(err).Msg("forced shutdown")
	}
	log.Info().Msg("api-gateway stopped")
}
EOF

# =============================================================================
# go.mod — add redis dependency
# =============================================================================
cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/api-gateway

go 1.22

require (
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
)

replace github.com/ecocomply/shared => ../shared
EOF

log "go.mod updated"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  api-gateway fix complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Files written:"
find "${BASE}/internal" -type f | sort | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "  cd api-gateway && go mod tidy && go build ./..."
echo ""
