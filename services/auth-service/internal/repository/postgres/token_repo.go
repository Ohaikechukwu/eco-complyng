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
	return dbWithContext(ctx, r.db).Exec(
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
	result := dbWithContext(ctx, r.db).Raw(
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
	return dbWithContext(ctx, r.db).Exec(
		"UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = ?",
		tokenHash,
	).Error
}

func (r *tokenRepository) RevokeAllUserTokens(ctx context.Context, userID uuid.UUID) error {
	return dbWithContext(ctx, r.db).Exec(
		"UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = ? AND revoked_at IS NULL",
		userID,
	).Error
}

// --- Password reset tokens ---

func (r *tokenRepository) SaveResetToken(ctx context.Context, userID uuid.UUID, tokenHash string, expiresAt time.Time) error {
	return dbWithContext(ctx, r.db).Exec(
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
	result := dbWithContext(ctx, r.db).Raw(
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
	return dbWithContext(ctx, r.db).Exec(
		"UPDATE password_reset_tokens SET used_at = NOW() WHERE token_hash = ?",
		tokenHash,
	).Error
}
