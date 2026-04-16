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
	r.RedirectTrailingSlash = false
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())
	r.Use(middleware.CORS())

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "export-service"})
	})

	h := handler.NewExportHandler(c.ExportService)
	v1 := r.Group("/api/v1/exports")
	v1.Use(middleware.Auth(c.JWTManager, c.Redis))
	v1.Use(middleware.Tenant(c.DB))
	v1.Use(middleware.RequireRole("org_admin", "manager"))
	{
		v1.POST("", h.CreateJob)
		v1.GET("", h.List)
	}
	return r
}
