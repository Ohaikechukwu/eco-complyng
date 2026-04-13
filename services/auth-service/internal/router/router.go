package router

import (
	"github.com/ecocomply/auth-service/internal/di"
	"github.com/ecocomply/auth-service/internal/handler"
	"github.com/ecocomply/auth-service/internal/handler/middleware"
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
	// CORS handled by api-gateway

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "auth-service"})
	})

	authHandler := handler.NewAuthHandler(c.AuthService, c.CookieConfig)

	v1 := r.Group("/api/v1/auth")
	{
		// Public routes
		v1.POST("/register", authHandler.RegisterOrg)
		v1.POST("/login", middleware.ResolveTenant(c.OrgRepo, c.TokenCache), authHandler.Login)
		v1.POST("/refresh", authHandler.RefreshToken)
		v1.POST("/forgot-password", middleware.ResolveTenant(c.OrgRepo, c.TokenCache), authHandler.ForgotPassword)
		v1.POST("/reset-password", authHandler.ResetPassword)

		// Protected routes
		protected := v1.Group("")
		protected.Use(middleware.Auth(c.JWTManager))
		protected.Use(middleware.Tenant(c.DB))
		{
			protected.POST("/logout", authHandler.Logout)
			protected.GET("/profile", authHandler.GetProfile)
			protected.PATCH("/profile", authHandler.UpdateProfile)
			protected.PATCH("/profile/password", authHandler.ChangePassword)

			adminOnly := protected.Group("/users")
			adminOnly.Use(middleware.RequireRole("org_admin"))
			{
				adminOnly.GET("", authHandler.ListUsers)
				adminOnly.POST("/invite", authHandler.InviteUser)
				adminOnly.PATCH("/:id/role", authHandler.UpdateRole)
			}
		}
	}

	return r
}
