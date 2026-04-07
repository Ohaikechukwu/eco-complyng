package middleware

import (
	"github.com/gin-gonic/gin"

	sharedcors "github.com/ecocomply/shared/pkg/cors"
)

func CORS() gin.HandlerFunc {
	return sharedcors.Middleware()
}
