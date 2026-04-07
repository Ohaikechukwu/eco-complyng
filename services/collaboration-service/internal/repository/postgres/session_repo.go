package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type sessionRepository struct{ db *gorm.DB }

func NewSessionRepository(db *gorm.DB) *sessionRepository {
	return &sessionRepository{db: db}
}

func (r *sessionRepository) Create(ctx context.Context, session *domain.CollabSession) error {
	return dbWithContext(ctx, r.db).Create(session).Error
}

func (r *sessionRepository) FindByInspection(ctx context.Context, inspectionID uuid.UUID) (*domain.CollabSession, error) {
	var session domain.CollabSession
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ? AND is_active = true", inspectionID).
		First(&session)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &session, result.Error
}

func (r *sessionRepository) AddParticipant(ctx context.Context, p *domain.CollabParticipant) error {
	return dbWithContext(ctx, r.db).
		Where(domain.CollabParticipant{SessionID: p.SessionID, UserID: p.UserID}).
		FirstOrCreate(p).Error
}

func (r *sessionRepository) RemoveParticipant(ctx context.Context, sessionID, userID uuid.UUID) error {
	return dbWithContext(ctx, r.db).
		Where("session_id = ? AND user_id = ?", sessionID, userID).
		Delete(&domain.CollabParticipant{}).Error
}

func (r *sessionRepository) CreateEvent(ctx context.Context, event *domain.CollabEvent) error {
	return dbWithContext(ctx, r.db).Create(event).Error
}

func (r *sessionRepository) UpsertAccess(ctx context.Context, access *domain.CollabAccess) error {
	return dbWithContext(ctx, r.db).
		Where(domain.CollabAccess{InspectionID: access.InspectionID, UserID: access.UserID}).
		Assign(access).
		FirstOrCreate(access).Error
}

func (r *sessionRepository) FindAccessByInspection(ctx context.Context, inspectionID uuid.UUID) ([]domain.CollabAccess, error) {
	var access []domain.CollabAccess
	err := dbWithContext(ctx, r.db).
		Where("inspection_id = ?", inspectionID).
		Order("created_at ASC").
		Find(&access).Error
	return access, err
}

func (r *sessionRepository) FindAccessForUser(ctx context.Context, inspectionID, userID uuid.UUID) (*domain.CollabAccess, error) {
	var access domain.CollabAccess
	result := dbWithContext(ctx, r.db).
		Where("inspection_id = ? AND user_id = ?", inspectionID, userID).
		First(&access)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &access, result.Error
}

func (r *sessionRepository) RevokeAccess(ctx context.Context, inspectionID, userID uuid.UUID) error {
	return dbWithContext(ctx, r.db).
		Model(&domain.CollabAccess{}).
		Where("inspection_id = ? AND user_id = ?", inspectionID, userID).
		Update("status", domain.AccessRevoked).Error
}
