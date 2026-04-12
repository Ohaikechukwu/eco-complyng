package middleware

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

func CSRFMiddleware(cookieName, headerName string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if isSafeMethod(c.Request.Method) || hasBearerToken(c.GetHeader("Authorization")) {
			c.Next()
			return
		}

		cookieValue, cookieErr := c.Cookie(cookieName)
		if cookieErr != nil || cookieValue == "" {
			c.Next()
			return
		}

		headerValue := strings.TrimSpace(c.GetHeader(headerName))
		if headerValue == "" || subtle.ConstantTimeCompare([]byte(headerValue), []byte(cookieValue)) != 1 {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{
				"success": false,
				"error":   "csrf token validation failed",
			})
			return
		}

		c.Next()
	}
}

func isSafeMethod(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return true
	default:
		return false
	}
}

func hasBearerToken(header string) bool {
	return strings.HasPrefix(header, "Bearer ")
}
