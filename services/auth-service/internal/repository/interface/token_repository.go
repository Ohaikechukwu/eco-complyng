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
