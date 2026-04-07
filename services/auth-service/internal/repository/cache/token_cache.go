package cache

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

var errInvalidRefreshTokenContext = errors.New("invalid refresh token context")

// TokenCache handles blacklisted access tokens in Redis.
// When a user logs out, their access token is blacklisted until it expires
// so it cannot be reused even if someone captured it.
type TokenCache struct {
	rdb *redis.Client
}

func NewTokenCache(rdb *redis.Client) *TokenCache {
	return &TokenCache{rdb: rdb}
}

func (c *TokenCache) BlacklistToken(ctx context.Context, tokenID string, ttl time.Duration) error {
	key := fmt.Sprintf("blacklist:%s", tokenID)
	return c.rdb.Set(ctx, key, "1", ttl).Err()
}

func (c *TokenCache) IsBlacklisted(ctx context.Context, tokenID string) (bool, error) {
	key := fmt.Sprintf("blacklist:%s", tokenID)
	result, err := c.rdb.Exists(ctx, key).Result()
	if err != nil {
		return false, err
	}
	return result > 0, nil
}

// CacheOrgSchema stores the org_id -> schema_name mapping so the tenant
// middleware doesn't hit Postgres on every request.
func (c *TokenCache) CacheOrgSchema(ctx context.Context, orgID, schemaName string) error {
	key := fmt.Sprintf("org_schema:%s", orgID)
	return c.rdb.Set(ctx, key, schemaName, 24*time.Hour).Err()
}

func (c *TokenCache) GetOrgSchema(ctx context.Context, orgID string) (string, error) {
	key := fmt.Sprintf("org_schema:%s", orgID)
	return c.rdb.Get(ctx, key).Result()
}

func (c *TokenCache) CacheRefreshTokenContext(ctx context.Context, tokenHash, orgID, schema string, ttl time.Duration) error {
	key := fmt.Sprintf("refresh_ctx:%s", tokenHash)
	return c.rdb.Set(ctx, key, orgID+"|"+schema, ttl).Err()
}

func (c *TokenCache) GetRefreshTokenContext(ctx context.Context, tokenHash string) (string, string, error) {
	key := fmt.Sprintf("refresh_ctx:%s", tokenHash)
	value, err := c.rdb.Get(ctx, key).Result()
	if err != nil {
		return "", "", err
	}

	parts := strings.SplitN(value, "|", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", errInvalidRefreshTokenContext
	}

	return parts[0], parts[1], nil
}

func (c *TokenCache) DeleteRefreshTokenContext(ctx context.Context, tokenHash string) error {
	key := fmt.Sprintf("refresh_ctx:%s", tokenHash)
	return c.rdb.Del(ctx, key).Err()
}
