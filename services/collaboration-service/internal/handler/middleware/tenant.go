package middleware

import (
	"github.com/ecocomply/shared/pkg/postgres"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const ContextDB = "tenant_db"

func Tenant(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		schema := c.GetString(ContextOrgSchema)
		if schema == "" {
			response.Unauthorized(c, "tenant context missing")
			c.Abort()
			return
		}

		tx, err := postgres.AttachTenantRequest(c, db, schema)
		if err != nil {
			response.InternalError(c, "failed to initialize tenant context")
			c.Abort()
			return
		}

		c.Set(ContextDB, tx)
		c.Next()

		if err := postgres.FinalizeTenantRequest(c, tx); err != nil {
			c.Error(err)
			c.Abort()
		}
	}
}
