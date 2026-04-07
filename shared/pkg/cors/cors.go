package cors

import (
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
)

const allowedHeaders = "Origin,Content-Type,Accept,Authorization"
const allowedMethods = "GET,POST,PUT,PATCH,DELETE,OPTIONS"

// Middleware applies a small CORS policy that is open in development and
// allowlist-driven in production via CORS_ALLOWED_ORIGINS.
func Middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if origin != "" {
			if !AllowOrigin(origin) {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{
					"success": false,
					"error":   "origin not allowed",
				})
				return
			}

			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Access-Control-Allow-Credentials", "true")
			c.Header("Vary", "Origin")
		}

		c.Header("Access-Control-Allow-Methods", allowedMethods)
		c.Header("Access-Control-Allow-Headers", allowedHeaders)

		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}

// AllowOrigin checks the incoming origin against CORS_ALLOWED_ORIGINS.
// In non-production environments, an empty allowlist defaults to allowing all.
func AllowOrigin(origin string) bool {
	if origin == "" {
		return true
	}

	allowed := parseAllowedOrigins(os.Getenv("CORS_ALLOWED_ORIGINS"))
	if len(allowed) == 0 {
		return os.Getenv("ENV") != "production"
	}

	for _, candidate := range allowed {
		if candidate == "*" || candidate == origin {
			return true
		}
	}

	return false
}

func parseAllowedOrigins(raw string) []string {
	if raw == "" {
		return nil
	}

	parts := strings.Split(raw, ",")
	origins := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			origins = append(origins, trimmed)
		}
	}

	return origins
}
