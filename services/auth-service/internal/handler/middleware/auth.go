package middleware

import (
	"strings"

	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
)

const (
	ContextUserID      = "user_id"
	ContextUserName    = "user_name"
	ContextOrgID       = "org_id"
	ContextOrgName     = "org_name"
	ContextOrgSchema   = "org_schema"
	ContextRole        = "role"
	ContextTokenID     = "token_id"
	ContextTokenExpiry = "token_expiry"
)

func Auth(jwtManager *sharedjwt.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := ExtractToken(c)
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
		role := c.GetString(ContextRole)
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
