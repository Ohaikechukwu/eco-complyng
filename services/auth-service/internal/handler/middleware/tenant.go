package middleware

import (
	"context"
	"strings"

	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"gorm.io/gorm"
)

const ContextDB = "tenant_db"

func Tenant(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
	}
}

func ResolveTenant(orgRepo irepository.OrgRepository, tokenCache *cache.TokenCache) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body struct {
			Email        string `json:"email"`
			OrgSchema    string `json:"org_schema"`
			Organization string `json:"organization"`
		}
		// Use ShouldBindBodyWith so body can be read again by the handler
		if err := c.ShouldBindBodyWith(&body, binding.JSON); err != nil || body.Email == "" {
			response.BadRequest(c, "email is required")
			c.Abort()
			return
		}

		ctx := context.Background()

		var resolvedOrgID, resolvedSchema, resolvedName string
		switch {
		case strings.TrimSpace(body.OrgSchema) != "":
			found, findErr := orgRepo.FindBySchemaName(ctx, strings.TrimSpace(body.OrgSchema))
			if findErr != nil {
				response.Unauthorized(c, "organisation not found")
				c.Abort()
				return
			}
			resolvedOrgID = found.ID.String()
			resolvedSchema = found.SchemaName
			resolvedName = found.Name
		case strings.TrimSpace(body.Organization) != "":
			schemaName := strings.TrimSpace(body.Organization)
			found, findErr := orgRepo.FindBySchemaName(ctx, schemaName)
			if findErr != nil {
				found, findErr = orgRepo.FindBySchemaName(ctx, "org_"+strings.ToLower(strings.ReplaceAll(schemaName, " ", "_")))
			}
			if findErr != nil {
				response.Unauthorized(c, "organisation not found")
				c.Abort()
				return
			}
			resolvedOrgID = found.ID.String()
			resolvedSchema = found.SchemaName
			resolvedName = found.Name
		default:
			found, findErr := orgRepo.FindByEmail(ctx, body.Email)
			if findErr != nil {
				response.Unauthorized(c, "organisation not found for this email; include org_schema or organization")
				c.Abort()
				return
			}
			resolvedOrgID = found.ID.String()
			resolvedSchema = found.SchemaName
			resolvedName = found.Name
		}

		_ = tokenCache.CacheOrgSchema(ctx, resolvedOrgID, resolvedSchema)

		c.Set(ContextOrgID, resolvedOrgID)
		c.Set(ContextOrgSchema, resolvedSchema)
		c.Set(ContextOrgName, resolvedName)
		c.Set("login_email", body.Email)
		c.Next()
	}
}
