package service

import (
	"context"
	"time"

	"github.com/ecocomply/notification-service/internal/domain"
	"github.com/ecocomply/notification-service/internal/dto/request"
	"github.com/ecocomply/notification-service/internal/dto/response"
	"github.com/ecocomply/notification-service/internal/email"
	irepository "github.com/ecocomply/notification-service/internal/repository/interface"
	"github.com/google/uuid"
)

type NotificationService struct {
	repo   irepository.NotificationRepository
	sender *email.Sender
}

func NewNotificationService(repo irepository.NotificationRepository, sender *email.Sender) *NotificationService {
	return &NotificationService{repo: repo, sender: sender}
}

func (s *NotificationService) Send(ctx context.Context, recipientEmail string, req request.SendNotificationRequest) (*response.NotificationResponse, error) {
	recipientID, err := uuid.Parse(req.RecipientID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}

	n := &domain.Notification{
		RecipientID: recipientID,
		Type:        domain.NotificationType(req.Type),
		Subject:     req.Subject,
		Body:        req.Body,
		Status:      domain.StatusPending,
	}

	if err := s.repo.Create(ctx, n); err != nil {
		return nil, err
	}

	// Send async
	go func() {
		err := s.sender.Send(recipientEmail, req.Subject, "report_share.html", map[string]string{
			"Body": req.Body,
		})
		bgCtx := context.Background()
		if err != nil {
			n.Status = domain.StatusFailed
			n.Error = err.Error()
		} else {
			n.Status = domain.StatusSent
			now := time.Now()
			n.SentAt = &now
		}
		_ = s.repo.Update(bgCtx, n)
	}()

	res := toResponse(n)
	return &res, nil
}

func (s *NotificationService) SendEmail(ctx context.Context, req request.SendEmailRequest) error {
	return s.sender.SendRaw(req.To, req.Subject, req.Body)
}

func (s *NotificationService) GetByRecipient(ctx context.Context, recipientID uuid.UUID, limit, offset int) ([]response.NotificationResponse, int64, error) {
	notifications, total, err := s.repo.FindByRecipient(ctx, recipientID, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	var res []response.NotificationResponse
	for _, n := range notifications {
		res = append(res, toResponse(&n))
	}
	return res, total, nil
}

func toResponse(n *domain.Notification) response.NotificationResponse {
	return response.NotificationResponse{
		ID:          n.ID.String(),
		RecipientID: n.RecipientID.String(),
		Type:        string(n.Type),
		Subject:     n.Subject,
		Status:      string(n.Status),
		SentAt:      n.SentAt,
		CreatedAt:   n.CreatedAt,
	}
}
