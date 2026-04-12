package middleware

import (
	"fmt"
	"net/http"
	"strings"

	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

// ValidateJWT validates the JWT and injects user context headers for downstream services.
// Downstream services trust these headers since they come from the gateway.
func ValidateJWT(jwtManager *sharedjwt.Manager, rdb *redis.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token == "" {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "missing token"})
			c.Abort()
			return
		}

		claims, err := jwtManager.Verify(token)
		if err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "invalid or expired token"})
			c.Abort()
			return
		}

		// Check token blacklist in Redis
		blacklistKey := fmt.Sprintf("blacklist:%s", claims.ID)
		exists, _ := rdb.Exists(c.Request.Context(), blacklistKey).Result()
		if exists > 0 {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "token has been revoked"})
			c.Abort()
			return
		}

		// Inject identity headers so downstream services don't re-validate JWT
		c.Request.Header.Set("X-User-ID", claims.UserID)
		c.Request.Header.Set("X-Org-ID", claims.OrgID)
		c.Request.Header.Set("X-Org-Schema", claims.OrgSchema)
		c.Request.Header.Set("X-User-Role", claims.Role)

		c.Next()
	}
}

// OptionalJWT validates the JWT only if present — used for public routes like share links.
func OptionalJWT(jwtManager *sharedjwt.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token != "" {
			if claims, err := jwtManager.Verify(token); err == nil {
				c.Request.Header.Set("X-User-ID", claims.UserID)
				c.Request.Header.Set("X-Org-ID", claims.OrgID)
				c.Request.Header.Set("X-Org-Schema", claims.OrgSchema)
				c.Request.Header.Set("X-User-Role", claims.Role)
			}
		}
		c.Next()
	}
}

func extractToken(c *gin.Context) string {
	bearer := c.GetHeader("Authorization")
	if strings.HasPrefix(bearer, "Bearer ") {
		return strings.TrimPrefix(bearer, "Bearer ")
	}
	cookie, err := c.Cookie("access_token")
	if err == nil {
		return cookie
	}
	return ""
}
