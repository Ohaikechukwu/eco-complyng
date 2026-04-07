package irepository

import (
	"context"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
)

type SessionRepository interface {
	Create(ctx context.Context, session *domain.CollabSession) error
	FindByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error)
	AddParticipant(ctx context.Context, p *domain.CollabParticipant) error
	RemoveParticipant(ctx context.Context, sessionID, userID uuid.UUID) error
	CreateEvent(ctx context.Context, event *domain.CollabEvent) error
	UpsertAccess(ctx context.Context, access *domain.CollabAccess) error
	FindAccessByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.CollabAccess, error)
	FindAccessForUser(ctx context.Context, inspectionID, userID uuid.UUID) (*domain.CollabAccess, error)
	RevokeAccess(ctx context.Context, inspectionID, userID uuid.UUID) error
}
