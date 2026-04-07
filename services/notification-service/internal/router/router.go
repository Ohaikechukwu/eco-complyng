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

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "notification-service"})
	})

	h := handler.NewNotificationHandler(c.NotificationService)
	v1 := r.Group("/api/v1/notifications")
	{
		v1.POST("/email", h.SendEmail)
	}
	protected := r.Group("/api/v1/notifications")
	protected.Use(middleware.Auth(c.JWTManager, c.Redis))
	protected.Use(middleware.Tenant(c.DB))
	{
		protected.GET("", h.List)
	}
	return r
}
