package irepository

import (
	"context"
	"github.com/ecocomply/notification-service/internal/domain"
	"github.com/google/uuid"
)

type NotificationRepository interface {
	Create(ctx context.Context, n *domain.Notification) error
	Update(ctx context.Context, n *domain.Notification) error
	FindByRecipient(ctx context.Context, recipientID uuid.UUID, limit, offset int) ([]domain.Notification, int64, error)
}
