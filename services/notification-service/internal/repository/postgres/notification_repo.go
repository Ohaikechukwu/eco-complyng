package postgres

import (
	"context"

	"github.com/ecocomply/notification-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type notificationRepository struct{ db *gorm.DB }

func NewNotificationRepository(db *gorm.DB) *notificationRepository {
	return &notificationRepository{db: db}
}

func (r *notificationRepository) Create(ctx context.Context, n *domain.Notification) error {
	return dbWithContext(ctx, r.db).Create(n).Error
}

func (r *notificationRepository) Update(ctx context.Context, n *domain.Notification) error {
	return dbWithContext(ctx, r.db).Save(n).Error
}

func (r *notificationRepository) FindByRecipient(ctx context.Context, recipientID uuid.UUID, limit, offset int) ([]domain.Notification, int64, error) {
	var notifications []domain.Notification
	var total int64
	dbWithContext(ctx, r.db).Model(&domain.Notification{}).Where("recipient_id = ?", recipientID).Count(&total)
	result := dbWithContext(ctx, r.db).
		Where("recipient_id = ?", recipientID).
		Order("created_at DESC").
		Limit(limit).Offset(offset).
		Find(&notifications)
	return notifications, total, result.Error
}
