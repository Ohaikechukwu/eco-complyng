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
	r.RedirectTrailingSlash = false
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "collaboration-service"})
	})

	h := handler.NewCollabHandler(c.CollabService, c.Hub)

	v1 := r.Group("/api/v1/collaborate")
	v1.Use(middleware.Auth(c.JWTManager, c.Redis))
	v1.Use(middleware.Tenant(c.DB))
	{
		v1.POST("/:inspection_id/share", middleware.RequireRole("org_admin", "supervisor", "manager", "enumerator"), h.Share)
		v1.GET("/:inspection_id/access", h.ListAccess)
		v1.DELETE("/:inspection_id/share/:user_id", middleware.RequireRole("org_admin", "supervisor", "manager"), h.Revoke)
		v1.GET("/:inspection_id/ws", h.ServeWS)
	}

	return r
}
