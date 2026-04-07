#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — auth-service complete build script
# Run from inside ~/ecocomply-ng:
#   chmod +x build_auth_service.sh && ./build_auth_service.sh
# =============================================================================

BASE="services/auth-service"
MODULE="github.com/ecocomply/auth-service"
SHARED="github.com/ecocomply/shared"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# 1. MIGRATIONS
# =============================================================================
info "Writing migrations..."

cat > "${BASE}/migrations/public/000001_create_orgs.up.sql" << 'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS orgs (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    schema_name TEXT        NOT NULL UNIQUE,
    email       TEXT        NOT NULL UNIQUE,
    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_orgs_schema_name ON orgs (schema_name);
CREATE INDEX IF NOT EXISTS idx_orgs_deleted_at  ON orgs (deleted_at);

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_orgs_updated_at
    BEFORE UPDATE ON orgs
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
EOF

cat > "${BASE}/migrations/public/000001_create_orgs.down.sql" << 'EOF'
DROP TRIGGER IF EXISTS set_orgs_updated_at ON orgs;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE IF EXISTS orgs;
EOF

cat > "${BASE}/migrations/public/000002_create_provision_org_fn.up.sql" << 'EOF'
CREATE OR REPLACE FUNCTION provision_org_schema(p_schema_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_schema TEXT := quote_ident(p_schema_name);
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %s', v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.user_role AS ENUM (
                'org_admin', 'manager', 'supervisor', 'enumerator'
            );
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.users (
            id              UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
            name            TEXT             NOT NULL,
            email           TEXT             NOT NULL UNIQUE,
            password_hash   TEXT             NOT NULL,
            role            %s.user_role     NOT NULL DEFAULT 'enumerator',
            is_active       BOOLEAN          NOT NULL DEFAULT TRUE,
            invited_by      UUID,
            last_login_at   TIMESTAMPTZ,
            created_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
            updated_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
            deleted_at      TIMESTAMPTZ,
            CONSTRAINT fk_invited_by FOREIGN KEY (invited_by)
                REFERENCES %s.users (id) ON DELETE SET NULL
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_email      ON %s.users (email)',      v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_role       ON %s.users (role)',       v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON %s.users (deleted_at)', v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.password_reset_tokens (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID        NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash  TEXT        NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            used_at     TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.refresh_tokens (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID        NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash  TEXT        NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            revoked_at  TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_rt_user_id    ON %s.refresh_tokens (user_id)',        v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_rt_expires_at ON %s.refresh_tokens (expires_at)',     v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_prt_user_id   ON %s.password_reset_tokens (user_id)', v_schema);

    EXECUTE format($fmt$
        CREATE OR REPLACE FUNCTION %s.trigger_set_updated_at()
        RETURNS TRIGGER AS $fn$
        BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
        $fn$ LANGUAGE plpgsql
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TRIGGER set_users_updated_at
            BEFORE UPDATE ON %s.users
            FOR EACH ROW
            EXECUTE FUNCTION %s.trigger_set_updated_at()
    $fmt$, v_schema, v_schema);
END;
$$ LANGUAGE plpgsql;
EOF

cat > "${BASE}/migrations/public/000002_create_provision_org_fn.down.sql" << 'EOF'
DROP FUNCTION IF EXISTS provision_org_schema(TEXT);
EOF

cat > "${BASE}/migrations/tenant/000001_create_users.up.sql" << 'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE user_role AS ENUM (
        'org_admin', 'manager', 'supervisor', 'enumerator'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS users (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT        NOT NULL,
    email           TEXT        NOT NULL UNIQUE,
    password_hash   TEXT        NOT NULL,
    role            user_role   NOT NULL DEFAULT 'enumerator',
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    invited_by      UUID,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,
    CONSTRAINT fk_invited_by FOREIGN KEY (invited_by)
        REFERENCES users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_users_email      ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_role       ON users (role);
CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON users (deleted_at);

CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash  TEXT        NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_prt_user_id    ON password_reset_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_prt_expires_at ON password_reset_tokens (expires_at);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash  TEXT        NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rt_user_id    ON refresh_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_rt_expires_at ON refresh_tokens (expires_at);

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
EOF

cat > "${BASE}/migrations/tenant/000001_create_users.down.sql" << 'EOF'
DROP TRIGGER IF EXISTS set_users_updated_at ON users;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE IF EXISTS refresh_tokens;
DROP TABLE IF EXISTS password_reset_tokens;
DROP TABLE IF EXISTS users;
DROP TYPE  IF EXISTS user_role;
EOF

log "Migrations done"

# =============================================================================
# 2. DOMAIN
# =============================================================================
info "Writing domain layer..."

cat > "${BASE}/internal/domain/user.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type Role string

const (
	RoleOrgAdmin   Role = "org_admin"
	RoleManager    Role = "manager"
	RoleSupervisor Role = "supervisor"
	RoleEnumerator Role = "enumerator"
)

type User struct {
	ID           uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Name         string     `gorm:"not null"`
	Email        string     `gorm:"uniqueIndex;not null"`
	PasswordHash string     `gorm:"not null"`
	Role         Role       `gorm:"type:user_role;not null;default:enumerator"`
	IsActive     bool       `gorm:"not null;default:true"`
	InvitedBy    *uuid.UUID `gorm:"type:uuid"`
	LastLoginAt  *time.Time
	CreatedAt    time.Time
	UpdatedAt    time.Time
	DeletedAt    *time.Time `gorm:"index"`
}

func (User) TableName() string { return "users" }
EOF

cat > "${BASE}/internal/domain/org.go" << 'EOF'
package domain

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Org struct {
	ID         uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Name       string     `gorm:"not null"`
	SchemaName string     `gorm:"uniqueIndex;not null"`
	Email      string     `gorm:"uniqueIndex;not null"`
	IsActive   bool       `gorm:"not null;default:true"`
	CreatedAt  time.Time
	UpdatedAt  time.Time
	DeletedAt  *time.Time `gorm:"index"`
}

func (Org) TableName() string { return "orgs" }

var nonAlphanumeric = regexp.MustCompile(`[^a-z0-9]+`)

// SchemaNameFrom converts an org name to a safe Postgres schema name.
// e.g. "Acme Corp Nigeria" → "org_acme_corp_nigeria"
func SchemaNameFrom(orgName string) string {
	lower := strings.ToLower(orgName)
	safe := nonAlphanumeric.ReplaceAllString(lower, "_")
	safe = strings.Trim(safe, "_")
	return fmt.Sprintf("org_%s", safe)
}
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound          = errors.New("record not found")
	ErrUnauthorized      = errors.New("unauthorized")
	ErrForbidden         = errors.New("forbidden")
	ErrAlreadyExists     = errors.New("record already exists")
	ErrInvalidInput      = errors.New("invalid input")
	ErrInternalServer    = errors.New("internal server error")
	ErrInvalidCredentials = errors.New("invalid email or password")
	ErrAccountInactive   = errors.New("account is inactive")
	ErrTokenExpired      = errors.New("token has expired")
	ErrTokenInvalid      = errors.New("token is invalid")
)
EOF

log "Domain layer done"

# =============================================================================
# 3. DTOs
# =============================================================================
info "Writing DTOs..."

cat > "${BASE}/internal/dto/request/auth_request.go" << 'EOF'
package request

// RegisterOrgRequest is used when a new organisation signs up.
// This creates the org row + provisions the isolated schema + seeds the org_admin user.
type RegisterOrgRequest struct {
	OrgName  string `json:"org_name"  binding:"required,min=2,max=100"`
	Email    string `json:"email"     binding:"required,email"`
	Password string `json:"password"  binding:"required,min=8"`
	Name     string `json:"name"      binding:"required,min=2,max=100"`
}

// LoginRequest is used for both org admin and member login.
type LoginRequest struct {
	Email    string `json:"email"    binding:"required,email"`
	Password string `json:"password" binding:"required"`
}

// RefreshTokenRequest is sent when the client needs a new access token.
type RefreshTokenRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

// ForgotPasswordRequest initiates a password reset email.
type ForgotPasswordRequest struct {
	Email string `json:"email" binding:"required,email"`
}

// ResetPasswordRequest completes the password reset flow.
type ResetPasswordRequest struct {
	Token       string `json:"token"        binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=8"`
}

// InviteUserRequest is used by org_admin to provision a new user.
type InviteUserRequest struct {
	Name  string `json:"name"  binding:"required,min=2,max=100"`
	Email string `json:"email" binding:"required,email"`
	Role  string `json:"role"  binding:"required,oneof=manager supervisor enumerator"`
}

// UpdateRoleRequest is used by org_admin to change a user's role.
type UpdateRoleRequest struct {
	Role string `json:"role" binding:"required,oneof=manager supervisor enumerator"`
}

// UpdateProfileRequest is used by any user to update their own profile.
type UpdateProfileRequest struct {
	Name string `json:"name" binding:"omitempty,min=2,max=100"`
}

// ChangePasswordRequest is used by a logged-in user to change their password.
type ChangePasswordRequest struct {
	CurrentPassword string `json:"current_password" binding:"required"`
	NewPassword     string `json:"new_password"     binding:"required,min=8"`
}
EOF

cat > "${BASE}/internal/dto/response/auth_response.go" << 'EOF'
package response

import "time"

// TokenPair is returned on login and token refresh.
type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresAt    int64  `json:"expires_at"` // unix timestamp
}

// UserResponse is the public-safe representation of a user.
type UserResponse struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Email       string     `json:"email"`
	Role        string     `json:"role"`
	IsActive    bool       `json:"is_active"`
	LastLoginAt *time.Time `json:"last_login_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

// OrgResponse is the public-safe representation of an org.
type OrgResponse struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	SchemaName string    `json:"schema_name"`
	Email      string    `json:"email"`
	IsActive   bool      `json:"is_active"`
	CreatedAt  time.Time `json:"created_at"`
}

// LoginResponse bundles the token pair with the authenticated user's profile.
type LoginResponse struct {
	Tokens TokenPair    `json:"tokens"`
	User   UserResponse `json:"user"`
	Org    OrgResponse  `json:"org"`
}

// RegisterOrgResponse is returned after a successful org registration.
type RegisterOrgResponse struct {
	Org  OrgResponse  `json:"org"`
	User UserResponse `json:"user"`
}
EOF

log "DTOs done"

# =============================================================================
# 4. REPOSITORY INTERFACES
# =============================================================================
info "Writing repository interfaces..."

cat > "${BASE}/internal/repository/interface/user_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
)

// UserRepository defines all data access operations for users.
// The postgres implementation lives in repository/postgres/user_repo.go.
// The mock lives in mocks/ and is generated by mockery.
type UserRepository interface {
	Create(ctx context.Context, user *domain.User) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.User, error)
	FindByEmail(ctx context.Context, email string) (*domain.User, error)
	Update(ctx context.Context, user *domain.User) error
	SoftDelete(ctx context.Context, id uuid.UUID) error
	List(ctx context.Context, limit, offset int) ([]domain.User, int64, error)
}
EOF

cat > "${BASE}/internal/repository/interface/org_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
)

// OrgRepository defines all data access operations for orgs.
// Operates on the public schema — no tenant scoping needed.
type OrgRepository interface {
	Create(ctx context.Context, org *domain.Org) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Org, error)
	FindByEmail(ctx context.Context, email string) (*domain.Org, error)
	FindBySchemaName(ctx context.Context, schemaName string) (*domain.Org, error)
	Update(ctx context.Context, org *domain.Org) error
	ProvisionSchema(ctx context.Context, schemaName string) error
}
EOF

cat > "${BASE}/internal/repository/interface/token_repository.go" << 'EOF'
package irepository

import (
	"context"
	"time"

	"github.com/google/uuid"
)

// TokenRepository handles refresh tokens and password reset tokens.
type TokenRepository interface {
	// Refresh tokens
	SaveRefreshToken(ctx context.Context, userID uuid.UUID, tokenHash string, expiresAt time.Time) error
	FindRefreshToken(ctx context.Context, tokenHash string) (userID uuid.UUID, expiresAt time.Time, err error)
	RevokeRefreshToken(ctx context.Context, tokenHash string) error
	RevokeAllUserTokens(ctx context.Context, userID uuid.UUID) error

	// Password reset tokens
	SaveResetToken(ctx context.Context, userID uuid.UUID, tokenHash string, expiresAt time.Time) error
	FindResetToken(ctx context.Context, tokenHash string) (userID uuid.UUID, expiresAt time.Time, used bool, err error)
	MarkResetTokenUsed(ctx context.Context, tokenHash string) error
}
EOF

log "Repository interfaces done"

# =============================================================================
# 5. REPOSITORY IMPLEMENTATIONS (POSTGRES)
# =============================================================================
info "Writing postgres repository implementations..."

cat > "${BASE}/internal/repository/postgres/user_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type userRepository struct {
	db *gorm.DB
}

func NewUserRepository(db *gorm.DB) *userRepository {
	return &userRepository{db: db}
}

func (r *userRepository) Create(ctx context.Context, user *domain.User) error {
	result := r.db.WithContext(ctx).Create(user)
	if result.Error != nil {
		if isUniqueViolation(result.Error) {
			return domain.ErrAlreadyExists
		}
		return result.Error
	}
	return nil
}

func (r *userRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.User, error) {
	var user domain.User
	result := r.db.WithContext(ctx).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&user)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &user, result.Error
}

func (r *userRepository) FindByEmail(ctx context.Context, email string) (*domain.User, error) {
	var user domain.User
	result := r.db.WithContext(ctx).
		Where("email = ? AND deleted_at IS NULL", email).
		First(&user)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &user, result.Error
}

func (r *userRepository) Update(ctx context.Context, user *domain.User) error {
	return r.db.WithContext(ctx).Save(user).Error
}

func (r *userRepository) SoftDelete(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).
		Model(&domain.User{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}

func (r *userRepository) List(ctx context.Context, limit, offset int) ([]domain.User, int64, error) {
	var users []domain.User
	var total int64

	r.db.WithContext(ctx).Model(&domain.User{}).
		Where("deleted_at IS NULL").
		Count(&total)

	result := r.db.WithContext(ctx).
		Where("deleted_at IS NULL").
		Order("created_at DESC").
		Limit(limit).Offset(offset).
		Find(&users)

	return users, total, result.Error
}
EOF

cat > "${BASE}/internal/repository/postgres/org_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type orgRepository struct {
	db *gorm.DB
}

func NewOrgRepository(db *gorm.DB) *orgRepository {
	return &orgRepository{db: db}
}

func (r *orgRepository) Create(ctx context.Context, org *domain.Org) error {
	result := r.db.WithContext(ctx).Create(org)
	if result.Error != nil {
		if isUniqueViolation(result.Error) {
			return domain.ErrAlreadyExists
		}
		return result.Error
	}
	return nil
}

func (r *orgRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Org, error) {
	var org domain.Org
	result := r.db.WithContext(ctx).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&org)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &org, result.Error
}

func (r *orgRepository) FindByEmail(ctx context.Context, email string) (*domain.Org, error) {
	var org domain.Org
	result := r.db.WithContext(ctx).
		Where("email = ? AND deleted_at IS NULL", email).
		First(&org)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &org, result.Error
}

func (r *orgRepository) FindBySchemaName(ctx context.Context, schemaName string) (*domain.Org, error) {
	var org domain.Org
	result := r.db.WithContext(ctx).
		Where("schema_name = ? AND deleted_at IS NULL", schemaName).
		First(&org)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &org, result.Error
}

func (r *orgRepository) Update(ctx context.Context, org *domain.Org) error {
	return r.db.WithContext(ctx).Save(org).Error
}

// ProvisionSchema calls the stored procedure that creates the org's
// isolated Postgres schema with all required tables in one transaction.
func (r *orgRepository) ProvisionSchema(ctx context.Context, schemaName string) error {
	return r.db.WithContext(ctx).
		Exec("SELECT provision_org_schema(?)", schemaName).Error
}
EOF

cat > "${BASE}/internal/repository/postgres/token_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type tokenRepository struct {
	db *gorm.DB
}

func NewTokenRepository(db *gorm.DB) *tokenRepository {
	return &tokenRepository{db: db}
}

// --- Refresh tokens ---

func (r *tokenRepository) SaveRefreshToken(ctx context.Context, userID uuid.UUID, tokenHash string, expiresAt time.Time) error {
	return r.db.WithContext(ctx).Exec(
		"INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
		userID, tokenHash, expiresAt,
	).Error
}

func (r *tokenRepository) FindRefreshToken(ctx context.Context, tokenHash string) (uuid.UUID, time.Time, error) {
	var row struct {
		UserID    uuid.UUID
		ExpiresAt time.Time
		RevokedAt *time.Time
	}
	result := r.db.WithContext(ctx).Raw(
		"SELECT user_id, expires_at, revoked_at FROM refresh_tokens WHERE token_hash = ?",
		tokenHash,
	).Scan(&row)

	if result.RowsAffected == 0 {
		return uuid.Nil, time.Time{}, domain.ErrNotFound
	}
	if row.RevokedAt != nil {
		return uuid.Nil, time.Time{}, domain.ErrTokenInvalid
	}
	if time.Now().After(row.ExpiresAt) {
		return uuid.Nil, time.Time{}, domain.ErrTokenExpired
	}
	return row.UserID, row.ExpiresAt, result.Error
}

func (r *tokenRepository) RevokeRefreshToken(ctx context.Context, tokenHash string) error {
	return r.db.WithContext(ctx).Exec(
		"UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = ?",
		tokenHash,
	).Error
}

func (r *tokenRepository) RevokeAllUserTokens(ctx context.Context, userID uuid.UUID) error {
	return r.db.WithContext(ctx).Exec(
		"UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = ? AND revoked_at IS NULL",
		userID,
	).Error
}

// --- Password reset tokens ---

func (r *tokenRepository) SaveResetToken(ctx context.Context, userID uuid.UUID, tokenHash string, expiresAt time.Time) error {
	return r.db.WithContext(ctx).Exec(
		"INSERT INTO password_reset_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
		userID, tokenHash, expiresAt,
	).Error
}

func (r *tokenRepository) FindResetToken(ctx context.Context, tokenHash string) (uuid.UUID, time.Time, bool, error) {
	var row struct {
		UserID    uuid.UUID
		ExpiresAt time.Time
		UsedAt    *time.Time
	}
	result := r.db.WithContext(ctx).Raw(
		"SELECT user_id, expires_at, used_at FROM password_reset_tokens WHERE token_hash = ?",
		tokenHash,
	).Scan(&row)

	if result.RowsAffected == 0 {
		return uuid.Nil, time.Time{}, false, domain.ErrNotFound
	}
	used := row.UsedAt != nil
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return uuid.Nil, time.Time{}, false, domain.ErrNotFound
	}
	return row.UserID, row.ExpiresAt, used, result.Error
}

func (r *tokenRepository) MarkResetTokenUsed(ctx context.Context, tokenHash string) error {
	return r.db.WithContext(ctx).Exec(
		"UPDATE password_reset_tokens SET used_at = NOW() WHERE token_hash = ?",
		tokenHash,
	).Error
}
EOF

cat > "${BASE}/internal/repository/postgres/helpers.go" << 'EOF'
package postgres

import (
	"strings"
)

// isUniqueViolation checks if a Postgres error is a unique constraint violation (code 23505).
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "23505") ||
		strings.Contains(err.Error(), "unique constraint") ||
		strings.Contains(err.Error(), "duplicate key")
}
EOF

log "Postgres repositories done"

# =============================================================================
# 6. REPOSITORY CACHE (REDIS)
# =============================================================================
info "Writing Redis cache repository..."

cat > "${BASE}/internal/repository/cache/token_cache.go" << 'EOF'
package cache

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

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

// CacheOrgSchema stores the org_id → schema_name mapping so the tenant
// middleware doesn't hit Postgres on every request.
func (c *TokenCache) CacheOrgSchema(ctx context.Context, orgID, schemaName string) error {
	key := fmt.Sprintf("org_schema:%s", orgID)
	return c.rdb.Set(ctx, key, schemaName, 24*time.Hour).Err()
}

func (c *TokenCache) GetOrgSchema(ctx context.Context, orgID string) (string, error) {
	key := fmt.Sprintf("org_schema:%s", orgID)
	return c.rdb.Get(ctx, key).Result()
}
EOF

log "Redis cache done"

# =============================================================================
# 7. SERVICE LAYER
# =============================================================================
info "Writing service layer..."

cat > "${BASE}/internal/service/auth_service.go" << 'EOF'
package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/ecocomply/auth-service/internal/dto/request"
	"github.com/ecocomply/auth-service/internal/dto/response"
	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"
)

type AuthService struct {
	userRepo  irepository.UserRepository
	orgRepo   irepository.OrgRepository
	tokenRepo irepository.TokenRepository
	tokenCache *cache.TokenCache
	jwt       *sharedjwt.Manager
}

func NewAuthService(
	userRepo irepository.UserRepository,
	orgRepo irepository.OrgRepository,
	tokenRepo irepository.TokenRepository,
	tokenCache *cache.TokenCache,
	jwt *sharedjwt.Manager,
) *AuthService {
	return &AuthService{
		userRepo:   userRepo,
		orgRepo:    orgRepo,
		tokenRepo:  tokenRepo,
		tokenCache: tokenCache,
		jwt:        jwt,
	}
}

// RegisterOrg creates a new org, provisions its isolated schema,
// and seeds the org_admin user — all in one flow.
func (s *AuthService) RegisterOrg(ctx context.Context, req request.RegisterOrgRequest) (*response.RegisterOrgResponse, error) {
	// 1. Check org email not already taken
	_, err := s.orgRepo.FindByEmail(ctx, req.Email)
	if err == nil {
		return nil, domain.ErrAlreadyExists
	}
	if !errors.Is(err, domain.ErrNotFound) {
		return nil, err
	}

	// 2. Build org
	schemaName := domain.SchemaNameFrom(req.OrgName)
	org := &domain.Org{
		Name:       req.OrgName,
		SchemaName: schemaName,
		Email:      req.Email,
		IsActive:   true,
	}

	// 3. Persist org row in public schema
	if err := s.orgRepo.Create(ctx, org); err != nil {
		return nil, err
	}

	// 4. Provision the isolated Postgres schema via stored procedure
	if err := s.orgRepo.ProvisionSchema(ctx, schemaName); err != nil {
		return nil, fmt.Errorf("schema provisioning failed: %w", err)
	}

	// 5. Hash password
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}

	// 6. Seed org_admin user inside the new tenant schema
	admin := &domain.User{
		Name:         req.Name,
		Email:        req.Email,
		PasswordHash: string(hash),
		Role:         domain.RoleOrgAdmin,
		IsActive:     true,
	}
	if err := s.userRepo.Create(ctx, admin); err != nil {
		return nil, err
	}

	// 7. Cache schema mapping for tenant middleware
	_ = s.tokenCache.CacheOrgSchema(ctx, org.ID.String(), schemaName)

	return &response.RegisterOrgResponse{
		Org:  toOrgResponse(org),
		User: toUserResponse(admin),
	}, nil
}

// Login authenticates a user and returns a token pair.
func (s *AuthService) Login(ctx context.Context, orgID uuid.UUID, req request.LoginRequest) (*response.LoginResponse, error) {
	// 1. Find user by email in tenant schema
	user, err := s.userRepo.FindByEmail(ctx, req.Email)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			return nil, domain.ErrInvalidCredentials
		}
		return nil, err
	}

	// 2. Check active
	if !user.IsActive {
		return nil, domain.ErrAccountInactive
	}

	// 3. Verify password
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		return nil, domain.ErrInvalidCredentials
	}

	// 4. Load org for response
	org, err := s.orgRepo.FindByID(ctx, orgID)
	if err != nil {
		return nil, err
	}

	// 5. Issue tokens
	tokens, err := s.issueTokenPair(ctx, user, org)
	if err != nil {
		return nil, err
	}

	// 6. Update last login
	now := time.Now()
	user.LastLoginAt = &now
	_ = s.userRepo.Update(ctx, user)

	return &response.LoginResponse{
		Tokens: *tokens,
		User:   toUserResponse(user),
		Org:    toOrgResponse(org),
	}, nil
}

// RefreshToken validates a refresh token and issues a new token pair.
func (s *AuthService) RefreshToken(ctx context.Context, orgID uuid.UUID, rawToken string) (*response.TokenPair, error) {
	tokenHash := hashToken(rawToken)

	userID, _, err := s.tokenRepo.FindRefreshToken(ctx, tokenHash)
	if err != nil {
		return nil, domain.ErrTokenInvalid
	}

	// Revoke old refresh token (rotation)
	_ = s.tokenRepo.RevokeRefreshToken(ctx, tokenHash)

	user, err := s.userRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	org, err := s.orgRepo.FindByID(ctx, orgID)
	if err != nil {
		return nil, err
	}

	return s.issueTokenPair(ctx, user, org)
}

// Logout blacklists the access token and revokes the refresh token.
func (s *AuthService) Logout(ctx context.Context, tokenID string, rawRefreshToken string, ttl time.Duration) error {
	_ = s.tokenCache.BlacklistToken(ctx, tokenID, ttl)
	if rawRefreshToken != "" {
		_ = s.tokenRepo.RevokeRefreshToken(ctx, hashToken(rawRefreshToken))
	}
	return nil
}

// InviteUser allows an org_admin to provision a new user in their tenant schema.
func (s *AuthService) InviteUser(ctx context.Context, inviterID uuid.UUID, req request.InviteUserRequest) (*response.UserResponse, error) {
	// Check email not taken
	_, err := s.userRepo.FindByEmail(ctx, req.Email)
	if err == nil {
		return nil, domain.ErrAlreadyExists
	}

	// Generate a temporary password — user must reset on first login
	rawTemp := generateToken(16)
	hash, err := bcrypt.GenerateFromPassword([]byte(rawTemp), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}

	user := &domain.User{
		Name:         req.Name,
		Email:        req.Email,
		PasswordHash: string(hash),
		Role:         domain.Role(req.Role),
		IsActive:     true,
		InvitedBy:    &inviterID,
	}

	if err := s.userRepo.Create(ctx, user); err != nil {
		return nil, err
	}

	// TODO: send invite email with rawTemp via notification-service

	res := toUserResponse(user)
	return &res, nil
}

// UpdateRole changes a user's role — org_admin only.
func (s *AuthService) UpdateRole(ctx context.Context, userID uuid.UUID, req request.UpdateRoleRequest) (*response.UserResponse, error) {
	user, err := s.userRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	user.Role = domain.Role(req.Role)
	if err := s.userRepo.Update(ctx, user); err != nil {
		return nil, err
	}
	res := toUserResponse(user)
	return &res, nil
}

// GetProfile returns the authenticated user's profile.
func (s *AuthService) GetProfile(ctx context.Context, userID uuid.UUID) (*response.UserResponse, error) {
	user, err := s.userRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	res := toUserResponse(user)
	return &res, nil
}

// UpdateProfile updates name or other safe fields.
func (s *AuthService) UpdateProfile(ctx context.Context, userID uuid.UUID, req request.UpdateProfileRequest) (*response.UserResponse, error) {
	user, err := s.userRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if req.Name != "" {
		user.Name = req.Name
	}
	if err := s.userRepo.Update(ctx, user); err != nil {
		return nil, err
	}
	res := toUserResponse(user)
	return &res, nil
}

// ChangePassword validates the current password and sets a new one.
func (s *AuthService) ChangePassword(ctx context.Context, userID uuid.UUID, req request.ChangePasswordRequest) error {
	user, err := s.userRepo.FindByID(ctx, userID)
	if err != nil {
		return err
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.CurrentPassword)); err != nil {
		return domain.ErrInvalidCredentials
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	user.PasswordHash = string(hash)
	return s.userRepo.Update(ctx, user)
}

// ListUsers returns paginated users — for supervisor/manager/org_admin.
func (s *AuthService) ListUsers(ctx context.Context, limit, offset int) ([]response.UserResponse, int64, error) {
	users, total, err := s.userRepo.List(ctx, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	var res []response.UserResponse
	for _, u := range users {
		res = append(res, toUserResponse(&u))
	}
	return res, total, nil
}

// --- helpers ---

func (s *AuthService) issueTokenPair(ctx context.Context, user *domain.User, org *domain.Org) (*response.TokenPair, error) {
	accessToken, err := s.jwt.Sign(user.ID.String(), org.ID.String(), org.SchemaName, string(user.Role))
	if err != nil {
		return nil, err
	}

	rawRefresh := generateToken(32)
	refreshHash := hashToken(rawRefresh)
	refreshExpiry := time.Now().Add(7 * 24 * time.Hour)

	if err := s.tokenRepo.SaveRefreshToken(ctx, user.ID, refreshHash, refreshExpiry); err != nil {
		return nil, err
	}

	return &response.TokenPair{
		AccessToken:  accessToken,
		RefreshToken: rawRefresh,
		ExpiresAt:    refreshExpiry.Unix(),
	}, nil
}

func hashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}

func generateToken(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func toUserResponse(u *domain.User) response.UserResponse {
	return response.UserResponse{
		ID:          u.ID.String(),
		Name:        u.Name,
		Email:       u.Email,
		Role:        string(u.Role),
		IsActive:    u.IsActive,
		LastLoginAt: u.LastLoginAt,
		CreatedAt:   u.CreatedAt,
	}
}

func toOrgResponse(o *domain.Org) response.OrgResponse {
	return response.OrgResponse{
		ID:         o.ID.String(),
		Name:       o.Name,
		SchemaName: o.SchemaName,
		Email:      o.Email,
		IsActive:   o.IsActive,
		CreatedAt:  o.CreatedAt,
	}
}
EOF

log "Service layer done"

# =============================================================================
# 8. HANDLERS
# =============================================================================
info "Writing HTTP handlers..."

cat > "${BASE}/internal/handler/auth_handler.go" << 'EOF'
package handler

import (
	"net/http"
	"time"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/ecocomply/auth-service/internal/dto/request"
	"github.com/ecocomply/auth-service/internal/handler/middleware"
	"github.com/ecocomply/auth-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type AuthHandler struct {
	svc *service.AuthService
}

func NewAuthHandler(svc *service.AuthService) *AuthHandler {
	return &AuthHandler{svc: svc}
}

// POST /api/v1/auth/register
func (h *AuthHandler) RegisterOrg(c *gin.Context) {
	var req request.RegisterOrgRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.RegisterOrg(c.Request.Context(), req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.Created(c, "organisation registered successfully", res)
}

// POST /api/v1/auth/login
func (h *AuthHandler) Login(c *gin.Context) {
	var req request.LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	orgID, _ := c.Get(middleware.ContextOrgID)
	parsedOrgID, err := uuid.Parse(orgID.(string))
	if err != nil {
		response.BadRequest(c, "invalid org context")
		return
	}

	res, err := h.svc.Login(c.Request.Context(), parsedOrgID, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}

	// Set httpOnly cookies
	setAuthCookies(c, res.Tokens.AccessToken, res.Tokens.RefreshToken)
	response.OK(c, "login successful", res)
}

// POST /api/v1/auth/refresh
func (h *AuthHandler) RefreshToken(c *gin.Context) {
	var req request.RefreshTokenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	orgID, _ := c.Get(middleware.ContextOrgID)
	parsedOrgID, _ := uuid.Parse(orgID.(string))

	tokens, err := h.svc.RefreshToken(c.Request.Context(), parsedOrgID, req.RefreshToken)
	if err != nil {
		response.Unauthorized(c, err.Error())
		return
	}

	setAuthCookies(c, tokens.AccessToken, tokens.RefreshToken)
	response.OK(c, "token refreshed", tokens)
}

// POST /api/v1/auth/logout
func (h *AuthHandler) Logout(c *gin.Context) {
	tokenID, _ := c.Get("token_id")
	refreshToken, _ := c.Cookie("refresh_token")

	_ = h.svc.Logout(c.Request.Context(), tokenID.(string), refreshToken, 24*time.Hour)

	// Clear cookies
	c.SetCookie("access_token", "", -1, "/", "", true, true)
	c.SetCookie("refresh_token", "", -1, "/", "", true, true)
	response.OK(c, "logged out successfully", nil)
}

// POST /api/v1/auth/users/invite  [org_admin only]
func (h *AuthHandler) InviteUser(c *gin.Context) {
	var req request.InviteUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	inviterID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.InviteUser(c.Request.Context(), inviterID, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.Created(c, "user invited successfully", res)
}

// PATCH /api/v1/auth/users/:id/role  [org_admin only]
func (h *AuthHandler) UpdateRole(c *gin.Context) {
	var req request.UpdateRoleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid user id")
		return
	}
	res, err := h.svc.UpdateRole(c.Request.Context(), userID, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "role updated", res)
}

// GET /api/v1/auth/profile
func (h *AuthHandler) GetProfile(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.GetProfile(c.Request.Context(), userID)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "profile retrieved", res)
}

// PATCH /api/v1/auth/profile
func (h *AuthHandler) UpdateProfile(c *gin.Context) {
	var req request.UpdateProfileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.UpdateProfile(c.Request.Context(), userID, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "profile updated", res)
}

// PATCH /api/v1/auth/profile/password
func (h *AuthHandler) ChangePassword(c *gin.Context) {
	var req request.ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	if err := h.svc.ChangePassword(c.Request.Context(), userID, req); err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "password changed successfully", nil)
}

// GET /api/v1/auth/users  [org_admin, manager, supervisor]
func (h *AuthHandler) ListUsers(c *gin.Context) {
	// TODO: wire pagination helper
	users, total, err := h.svc.ListUsers(c.Request.Context(), 20, 0)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "users retrieved", gin.H{"users": users, "total": total})
}

// --- helpers ---

func setAuthCookies(c *gin.Context, accessToken, refreshToken string) {
	secure := c.Request.TLS != nil
	c.SetCookie("access_token", accessToken, 3600*24, "/", "", secure, true)
	c.SetCookie("refresh_token", refreshToken, 3600*24*7, "/api/v1/auth/refresh", "", secure, true)
}

func handleServiceError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrAlreadyExists:
		c.JSON(http.StatusConflict, gin.H{"success": false, "error": err.Error()})
	case domain.ErrUnauthorized, domain.ErrInvalidCredentials:
		response.Unauthorized(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrAccountInactive:
		response.Forbidden(c, err.Error())
	case domain.ErrTokenExpired, domain.ErrTokenInvalid:
		response.Unauthorized(c, err.Error())
	default:
		response.InternalError(c, "something went wrong")
	}
}
EOF

log "Handlers done"

# =============================================================================
# 9. ROUTER
# =============================================================================
info "Writing router..."

cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"github.com/ecocomply/auth-service/internal/di"
	"github.com/ecocomply/auth-service/internal/handler"
	"github.com/ecocomply/auth-service/internal/handler/middleware"
	"github.com/gin-gonic/gin"
)

func New(c *di.Container) *gin.Engine {
	if c.Config.Env == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())
	r.Use(middleware.CORS())

	// Health check
	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "auth-service"})
	})

	authHandler := handler.NewAuthHandler(c.AuthService)

	v1 := r.Group("/api/v1/auth")
	{
		// Public routes — no JWT required
		v1.POST("/register", authHandler.RegisterOrg)
		v1.POST("/login", middleware.ResolveTenant(c.OrgRepo, c.TokenCache), authHandler.Login)
		v1.POST("/refresh", authHandler.RefreshToken)

		// Protected routes — JWT + tenant required
		protected := v1.Group("")
		protected.Use(middleware.Auth(c.JWTManager))
		protected.Use(middleware.Tenant(c.DB))
		{
			protected.POST("/logout", authHandler.Logout)

			// Profile
			protected.GET("/profile", authHandler.GetProfile)
			protected.PATCH("/profile", authHandler.UpdateProfile)
			protected.PATCH("/profile/password", authHandler.ChangePassword)

			// User management — org_admin only
			adminOnly := protected.Group("/users")
			adminOnly.Use(middleware.RequireRole("org_admin"))
			{
				adminOnly.GET("", authHandler.ListUsers)
				adminOnly.POST("/invite", authHandler.InviteUser)
				adminOnly.PATCH("/:id/role", authHandler.UpdateRole)
			}
		}
	}

	return r
}
EOF

log "Router done"

# =============================================================================
# 10. TENANT MIDDLEWARE UPDATE (resolves org from login email domain)
# =============================================================================
info "Writing ResolveTenant middleware..."

cat > "${BASE}/internal/handler/middleware/tenant.go" << 'EOF'
package middleware

import (
	"context"

	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	"github.com/ecocomply/shared/pkg/postgres"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const ContextDB = "tenant_db"

// Tenant sets the scoped DB on the context after Auth middleware has run.
// Used on protected routes where org_schema is already in the JWT claims.
func Tenant(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		schema, exists := c.Get(ContextOrgSchema)
		if !exists || schema == "" {
			response.Unauthorized(c, "tenant context missing")
			c.Abort()
			return
		}
		tenantDB := postgres.WithSchema(db, schema.(string))
		c.Set(ContextDB, tenantDB)
		c.Next()
	}
}

// ResolveTenant is used on the login route — before JWT exists.
// It resolves the org from the request body email, sets org_id and org_schema
// on the context so the login handler can use them.
func ResolveTenant(orgRepo irepository.OrgRepository, tokenCache *cache.TokenCache) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Peek at email without consuming the body
		var body struct {
			Email string `json:"email"`
		}
		if err := c.ShouldBindJSON(&body); err != nil || body.Email == "" {
			response.BadRequest(c, "email is required")
			c.Abort()
			return
		}

		// Try cache first
		ctx := context.Background()

		// Fall back to DB lookup by email — find org whose email matches
		org, err := orgRepo.FindByEmail(ctx, body.Email)
		if err != nil {
			// Email may belong to a member, not the org itself — 
			// for MVP, org email and admin email are the same at registration.
			// Post-MVP: look up user email → org_id mapping.
			response.Unauthorized(c, "organisation not found for this email")
			c.Abort()
			return
		}

		// Cache the mapping
		_ = tokenCache.CacheOrgSchema(ctx, org.ID.String(), org.SchemaName)

		c.Set(ContextOrgID, org.ID.String())
		c.Set(ContextOrgSchema, org.SchemaName)

		// Re-bind body for the login handler
		c.Set("login_email", body.Email)
		c.Next()
	}
}
EOF

log "Tenant middleware updated"

# =============================================================================
# 11. DI / WIRE
# =============================================================================
info "Writing dependency injection container..."

cat > "${BASE}/internal/di/wire.go" << 'EOF'
package di

import (
	"fmt"

	"github.com/ecocomply/auth-service/internal/config"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/postgres"
	"github.com/ecocomply/auth-service/internal/service"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config     *config.Config
	DB         *gorm.DB
	Redis      *redis.Client
	JWTManager *sharedjwt.Manager
	TokenCache *cache.TokenCache

	// Repositories (interfaces)
	UserRepo  irepository.UserRepository
	OrgRepo   irepository.OrgRepository
	TokenRepo irepository.TokenRepository

	// Services
	AuthService *service.AuthService
}

func NewContainer(cfg *config.Config) (*Container, error) {
	// DB
	db, err := sharedpostgres.Connect(sharedpostgres.Config{
		Host:     cfg.DBHost,
		Port:     cfg.DBPort,
		User:     cfg.DBUser,
		Password: cfg.DBPassword,
		DBName:   cfg.DBName,
	})
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}

	// Redis
	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host:     cfg.RedisHost,
		Port:     cfg.RedisPort,
		Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}

	// JWT manager
	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)

	// Cache
	tokenCache := cache.NewTokenCache(rdb)

	// Repositories — public schema uses default DB (no tenant scoping)
	orgRepo   := postgres.NewOrgRepository(db)
	// User and token repos operate on the tenant-scoped DB.
	// They are constructed with the base DB here; the tenant middleware
	// swaps the DB in context per request. Handlers extract it via c.Get(ContextDB).
	userRepo  := postgres.NewUserRepository(db)
	tokenRepo := postgres.NewTokenRepository(db)

	// Service
	authSvc := service.NewAuthService(userRepo, orgRepo, tokenRepo, tokenCache, jwtManager)

	return &Container{
		Config:      cfg,
		DB:          db,
		Redis:       rdb,
		JWTManager:  jwtManager,
		TokenCache:  tokenCache,
		UserRepo:    userRepo,
		OrgRepo:     orgRepo,
		TokenRepo:   tokenRepo,
		AuthService: authSvc,
	}, nil
}
EOF

log "DI container done"

# =============================================================================
# 12. go.mod UPDATE
# =============================================================================
info "Updating go.mod..."

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/auth-service

go 1.22

require (
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	github.com/stretchr/testify v1.9.0
	golang.org/x/crypto v0.22.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "go.mod updated"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  auth-service build complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Files written:"
find "${BASE}" -type f | sort | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "  1. cd ${BASE} && go mod tidy"
echo "  2. go build ./..."
echo ""