package middleware

import (
	"strings"

	"github.com/ecocomply/shared/pkg/jwt"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

const (
	ContextUserID      = "user_id"
	ContextUserName    = "user_name"
	ContextOrgID       = "org_id"
	ContextOrgSchema   = "org_schema"
	ContextRole        = "role"
	ContextTokenID     = "token_id"
	ContextTokenExpiry = "token_expiry"
)

func Auth(jwtManager *jwt.Manager, rdb *redis.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
		if token == "" {
			response.Unauthorized(c, "missing token")
			c.Abort()
			return
		}

		claims, err := jwtManager.Verify(token)
		if err != nil {
			response.Unauthorized(c, "invalid or expired token")
			c.Abort()
			return
		}

		if claims.ID != "" && rdb != nil {
			blacklisted, err := rdb.Exists(c.Request.Context(), "blacklist:"+claims.ID).Result()
			if err != nil {
				response.InternalError(c, "failed to validate token")
				c.Abort()
				return
			}
			if blacklisted > 0 {
				response.Unauthorized(c, "token is no longer valid")
				c.Abort()
				return
			}
		}

		c.Set(ContextUserID, claims.UserID)
		c.Set(ContextUserName, claims.Name)
		c.Set(ContextOrgID, claims.OrgID)
		c.Set(ContextOrgSchema, claims.OrgSchema)
		c.Set(ContextRole, claims.Role)
		if claims.ID != "" {
			c.Set(ContextTokenID, claims.ID)
		}
		if claims.ExpiresAt != nil {
			c.Set(ContextTokenExpiry, claims.ExpiresAt.Time.UTC())
		}

		c.Next()
	}
}

func RequireRole(roles ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		role, _ := c.Get(ContextRole)
		for _, r := range roles {
			if r == role {
				c.Next()
				return
			}
		}
		response.Forbidden(c, "insufficient permissions")
		c.Abort()
	}
}

func ExtractToken(c *gin.Context) string {
	return extractToken(c)
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
