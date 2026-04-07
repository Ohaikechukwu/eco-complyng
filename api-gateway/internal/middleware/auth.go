package middleware

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"
)

type GatewayClaims struct {
	UserID    string `json:"user_id"`
	OrgID     string `json:"org_id"`
	OrgSchema string `json:"org_schema"`
	Role      string `json:"role"`
	jwt.RegisteredClaims
}

// ValidateJWT validates the JWT and injects user context headers for downstream services.
// Downstream services trust these headers since they come from the gateway.
func ValidateJWT(secret string, rdb *redis.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token == "" {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "missing token"})
			c.Abort()
			return
		}

		claims, err := parseToken(token, secret)
		if err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": "invalid or expired token"})
			c.Abort()
			return
		}

		// Check token blacklist in Redis
		blacklistKey := fmt.Sprintf("blacklist:%s", claims.ID)
		exists, _ := rdb.Exists(context.Background(), blacklistKey).Result()
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
func OptionalJWT(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token != "" {
			if claims, err := parseToken(token, secret); err == nil {
				c.Request.Header.Set("X-User-ID", claims.UserID)
				c.Request.Header.Set("X-Org-ID", claims.OrgID)
				c.Request.Header.Set("X-Org-Schema", claims.OrgSchema)
				c.Request.Header.Set("X-User-Role", claims.Role)
			}
		}
		c.Next()
	}
}

func parseToken(tokenStr, secret string) (*GatewayClaims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &GatewayClaims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return []byte(secret), nil
	})
	if err != nil || !token.Valid {
		return nil, fmt.Errorf("invalid token")
	}
	claims, ok := token.Claims.(*GatewayClaims)
	if !ok {
		return nil, fmt.Errorf("invalid claims")
	}
	if claims.ExpiresAt != nil && claims.ExpiresAt.Before(time.Now()) {
		return nil, fmt.Errorf("token expired")
	}
	return claims, nil
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
