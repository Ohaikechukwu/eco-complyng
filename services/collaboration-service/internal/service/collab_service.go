package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/ecocomply/collaboration-service/internal/domain"
	"github.com/ecocomply/collaboration-service/internal/dto/request"
	"github.com/ecocomply/collaboration-service/internal/dto/response"
	irepository "github.com/ecocomply/collaboration-service/internal/repository/interface"
	"github.com/google/uuid"
)

type CollabService struct {
	sessionRepo irepository.SessionRepository
}

func NewCollabService(sessionRepo irepository.SessionRepository) *CollabService {
	return &CollabService{sessionRepo: sessionRepo}
}

// GetOrCreateSession returns an existing active session for an inspection
// or creates a new one.
func (s *CollabService) GetOrCreateSession(ctx context.Context, inspectionID, userID uuid.UUID) (*domain.CollabSession, error) {
	session, err := s.sessionRepo.FindByInspection(ctx, inspectionID)
	if err == nil && session.IsActive {
		return session, nil
	}

	session = &domain.CollabSession{
		InspectionID: inspectionID,
		CreatedBy:    userID,
		IsActive:     true,
	}
	if err := s.sessionRepo.Create(ctx, session); err != nil {
		return nil, err
	}
	return session, nil
}

// RecordEvent persists a WebSocket event to the collab_events table.
func (s *CollabService) RecordEvent(ctx context.Context, sessionID, userID uuid.UUID, eventType domain.EventType, payload interface{}) error {
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return domain.ErrInvalidInput
	}

	event := &domain.CollabEvent{
		SessionID: sessionID,
		UserID:    userID,
		EventType: string(eventType),
		Payload:   payloadBytes,
		CreatedAt: time.Now(),
	}
	return s.sessionRepo.CreateEvent(ctx, event)
}

// AddParticipant records a user joining a session.
func (s *CollabService) AddParticipant(ctx context.Context, sessionID, userID uuid.UUID) error {
	participant := &domain.CollabParticipant{
		SessionID: sessionID,
		UserID:    userID,
		JoinedAt:  time.Now(),
	}
	return s.sessionRepo.AddParticipant(ctx, participant)
}

// RemoveParticipant records a user leaving a session.
func (s *CollabService) RemoveParticipant(ctx context.Context, sessionID, userID uuid.UUID) error {
	return s.sessionRepo.RemoveParticipant(ctx, sessionID, userID)
}

func (s *CollabService) ShareInspection(ctx context.Context, inspectionID, invitedBy uuid.UUID, req request.ShareInspectionRequest) (*response.AccessResponse, error) {
	userID, err := uuid.Parse(req.UserID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	access := &domain.CollabAccess{
		InspectionID: inspectionID,
		UserID:       userID,
		Permission:   domain.PermissionLevel(req.Permission),
		Status:       domain.AccessActive,
		InvitedBy:    invitedBy,
	}
	if err := s.sessionRepo.UpsertAccess(ctx, access); err != nil {
		return nil, err
	}
	res := toAccessResponse(access)
	return &res, nil
}

func (s *CollabService) ListAccess(ctx context.Context, inspectionID uuid.UUID) ([]response.AccessResponse, error) {
	accessList, err := s.sessionRepo.FindAccessByInspection(ctx, inspectionID)
	if err != nil {
		return nil, err
	}
	res := make([]response.AccessResponse, 0, len(accessList))
	for _, item := range accessList {
		res = append(res, toAccessResponse(&item))
	}
	return res, nil
}

func (s *CollabService) RevokeAccess(ctx context.Context, inspectionID, userID uuid.UUID) error {
	return s.sessionRepo.RevokeAccess(ctx, inspectionID, userID)
}

func (s *CollabService) EnsureAccess(ctx context.Context, inspectionID, userID uuid.UUID) error {
	access, err := s.sessionRepo.FindAccessForUser(ctx, inspectionID, userID)
	if err == nil && access.Status == domain.AccessActive {
		return nil
	}
	session, sessErr := s.sessionRepo.FindByInspection(ctx, inspectionID)
	if sessErr == nil && session.CreatedBy == userID {
		return nil
	}
	if err == domain.ErrNotFound || sessErr == domain.ErrNotFound {
		return domain.ErrForbidden
	}
	if err != nil && err != domain.ErrNotFound {
		return err
	}
	return domain.ErrForbidden
}

func toAccessResponse(a *domain.CollabAccess) response.AccessResponse {
	return response.AccessResponse{
		ID:           a.ID.String(),
		InspectionID: a.InspectionID.String(),
		UserID:       a.UserID.String(),
		Permission:   string(a.Permission),
		Status:       string(a.Status),
		InvitedBy:    a.InvitedBy.String(),
		CreatedAt:    a.CreatedAt,
		UpdatedAt:    a.UpdatedAt,
	}
}
