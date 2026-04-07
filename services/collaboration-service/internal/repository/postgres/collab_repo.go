package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type collabRepository struct {
	db *gorm.DB
}

func NewCollabRepository(db *gorm.DB) *collabRepository {
	return &collabRepository{db: db}
}

func (r *collabRepository) CreateSession(ctx context.Context, session *domain.CollabSession) error {
	return dbWithContext(ctx, r.db).Create(session).Error
}

func (r *collabRepository) FindSessionByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error) {
	var session domain.CollabSession
	result := dbWithContext(ctx, r.db).
		Preload("Participants").
		Where("inspection_id = ? AND is_active = true", inspectionID).
		First(&session)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &session, result.Error
}

func (r *collabRepository) FindSessionByID(ctx context.Context, id uuid.UUID) (*domain.CollabSession, error) {
	var session domain.CollabSession
	result := dbWithContext(ctx, r.db).
		Preload("Participants").
		Where("id = ?", id).
		First(&session)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &session, result.Error
}

func (r *collabRepository) UpdateSession(ctx context.Context, session *domain.CollabSession) error {
	return dbWithContext(ctx, r.db).Save(session).Error
}

func (r *collabRepository) AddParticipant(ctx context.Context, p *domain.CollabParticipant) error {
	return dbWithContext(ctx, r.db).
		Where(domain.CollabParticipant{SessionID: p.SessionID, UserID: p.UserID}).
		FirstOrCreate(p).Error
}

func (r *collabRepository) UpdateParticipant(ctx context.Context, p *domain.CollabParticipant) error {
	return dbWithContext(ctx, r.db).Save(p).Error
}

func (r *collabRepository) FindParticipant(ctx context.Context, sessionID, userID uuid.UUID) (*domain.CollabParticipant, error) {
	var p domain.CollabParticipant
	result := dbWithContext(ctx, r.db).
		Where("session_id = ? AND user_id = ?", sessionID, userID).
		First(&p)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &p, result.Error
}

func (r *collabRepository) LogEvent(ctx context.Context, event *domain.CollabEvent) error {
	return dbWithContext(ctx, r.db).Create(event).Error
}
