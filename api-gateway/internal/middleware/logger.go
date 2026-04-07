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
