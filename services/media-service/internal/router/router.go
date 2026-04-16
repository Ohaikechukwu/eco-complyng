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
	r.RedirectTrailingSlash = false
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
	v1.Use(middleware.Auth(c.JWTManager, c.Redis))
	v1.Use(middleware.Tenant(c.DB))
	{
		v1.POST("", h.Upload)
		v1.GET("", h.GetByInspection)
		v1.DELETE("/:id", h.Delete)
	}

	return r
}
