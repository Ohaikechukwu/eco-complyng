package router

import (
	"github.com/ecocomply/inspection-service/internal/di"
	"github.com/ecocomply/inspection-service/internal/handler"
	"github.com/ecocomply/inspection-service/internal/handler/middleware"
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
		ctx.JSON(200, gin.H{"status": "ok", "service": "inspection-service"})
	})

	h := handler.NewInspectionHandler(c.InspectionService)

	v1 := r.Group("/api/v1/inspections")
	v1.Use(middleware.Auth(c.JWTManager, c.Redis))
	v1.Use(middleware.Tenant(c.DB))
	{
		// Dashboard
		v1.GET("/dashboard", h.Dashboard)
		v1.GET("/analytics", h.Analytics)
		v1.GET("/analytics/compare", h.AnalyticsCompare)
		v1.GET("/analytics/geojson", h.AnalyticsGeoJSON)
		v1.GET("/sync", h.SyncPull)

		// Templates — all authenticated users can read; org_admin creates
		v1.GET("/templates", h.ListTemplates)
		v1.POST("/templates", middleware.RequireRole("org_admin", "manager"), h.CreateTemplate)

		// Inspections
		v1.GET("", h.List)
		v1.POST("", h.Create)
		v1.GET("/:id", h.GetByID)
		v1.PATCH("/:id", h.Update)
		v1.POST("/:id/offline-merge", h.OfflineMerge)
		v1.DELETE("/:id", middleware.RequireRole("org_admin", "enumerator"), h.Delete)
		v1.PATCH("/:id/status", h.TransitionStatus)

		// Checklist items
		v1.POST("/:id/checklist", h.AddChecklistItem)
		v1.PATCH("/:id/checklist/:itemId", h.UpdateChecklistItem)

		// Actions
		v1.POST("/:id/actions", middleware.RequireRole("org_admin", "supervisor", "manager"), h.CreateAction)
		v1.PATCH("/:id/actions/:actionId", h.UpdateAction)

		// Comments
		v1.POST("/:id/comments", middleware.RequireRole("supervisor", "manager", "org_admin"), h.AddComment)
		v1.POST("/:id/reviews", middleware.RequireRole("supervisor", "manager", "org_admin"), h.CreateReview)
		v1.PATCH("/:id/reviews/:reviewId", h.UpdateReview)
	}

	return r
}
