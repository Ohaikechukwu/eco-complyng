package irepository

import (
	"context"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
)

type CollabRepository interface {
	CreateSession(ctx context.Context, session *domain.CollabSession) error
	FindSessionByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error)
	FindSessionByID(ctx context.Context, id uuid.UUID) (*domain.CollabSession, error)
	UpdateSession(ctx context.Context, session *domain.CollabSession) error

	AddParticipant(ctx context.Context, p *domain.CollabParticipant) error
	UpdateParticipant(ctx context.Context, p *domain.CollabParticipant) error
	FindParticipant(ctx context.Context, sessionID, userID uuid.UUID) (*domain.CollabParticipant, error)

	LogEvent(ctx context.Context, event *domain.CollabEvent) error
}
