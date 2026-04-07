package router

import (
	"github.com/ecocomply/report-service/internal/di"
	"github.com/ecocomply/report-service/internal/handler"
	"github.com/ecocomply/report-service/internal/handler/middleware"
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
		ctx.JSON(200, gin.H{"status": "ok", "service": "report-service"})
	})

	h := handler.NewReportHandler(c.ReportService)

	v1 := r.Group("/api/v1/reports")
	{
		// Public — share link access
		v1.GET("/share/:token", h.GetByShareToken)

		// Protected
		protected := v1.Group("")
		protected.Use(middleware.Auth(c.JWTManager, c.Redis))
		protected.Use(middleware.Tenant(c.DB))
		{
			protected.POST("/generate", h.Generate)
			protected.GET("", h.GetByInspection)
			protected.GET("/:id", h.GetByID)
			protected.POST("/:id/share", h.CreateShareLink)
		}
	}

	return r
}
