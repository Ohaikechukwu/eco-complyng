package middleware

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

// RateLimit uses a Redis sliding window counter per IP.
// limit = max requests per window duration.
func RateLimit(rdb *redis.Client, limit int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()
		key := fmt.Sprintf("rate:%s", ip)

		ctx := context.Background()
		pipe := rdb.Pipeline()
		incr := pipe.Incr(ctx, key)
		pipe.Expire(ctx, key, window)
		pipe.Exec(ctx)

		count := incr.Val()
		if count > int64(limit) {
			c.JSON(http.StatusTooManyRequests, gin.H{
				"success": false,
				"error":   "too many requests — slow down",
			})
			c.Abort()
			return
		}

		c.Header("X-RateLimit-Limit", fmt.Sprintf("%d", limit))
		c.Header("X-RateLimit-Remaining", fmt.Sprintf("%d", int64(limit)-count))
		c.Next()
	}
}

// StrictRateLimit applies a tighter limit for sensitive routes (login, register).
func StrictRateLimit(rdb *redis.Client) gin.HandlerFunc {
	return RateLimit(rdb, 200, time.Minute) // 200 req/min per IP
}

// DefaultRateLimit applies a general limit for all other routes.
func DefaultRateLimit(rdb *redis.Client) gin.HandlerFunc {
	return RateLimit(rdb, 300, time.Minute) // 300 req/min per IP
}
