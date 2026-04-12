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
	r.Use(middleware.CSRFMiddleware(c.Config.CSRFCookieName, c.Config.CSRFHeaderName))

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
			auth.POST("/register", c.AuthProxy.Handler())
			auth.POST("/login", c.AuthProxy.Handler())
			auth.POST("/refresh", c.AuthProxy.Handler())
			auth.POST("/forgot-password", c.AuthProxy.Handler())
			auth.POST("/reset-password", c.AuthProxy.Handler())

			// Protected auth routes
			authProtected := auth.Group("")
			authProtected.Use(middleware.ValidateJWT(c.JWTManager, c.Redis))
			{
				authProtected.POST("/logout", c.AuthProxy.Handler())
				authProtected.GET("/profile", c.AuthProxy.Handler())
				authProtected.PATCH("/profile", c.AuthProxy.Handler())
				authProtected.PATCH("/profile/password", c.AuthProxy.Handler())
				authProtected.GET("/users", c.AuthProxy.Handler())
				authProtected.POST("/users/invite", c.AuthProxy.Handler())
				authProtected.PATCH("/users/:id/role", c.AuthProxy.Handler())
			}
		}

		// ── All other services — JWT required ─────────────────────────────────
		protected := v1.Group("")
		protected.Use(middleware.ValidateJWT(c.JWTManager, c.Redis))
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
					middleware.OptionalJWT(c.JWTManager)(ctx)
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
