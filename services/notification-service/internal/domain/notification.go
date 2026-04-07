package domain

import (
	"github.com/google/uuid"
	"time"
)

type NotificationStatus string

const (
	StatusPending NotificationStatus = "pending"
	StatusSent    NotificationStatus = "sent"
	StatusFailed  NotificationStatus = "failed"
)

type NotificationType string

const (
	TypeInvite           NotificationType = "invite"
	TypeDeadlineReminder NotificationType = "deadline_reminder"
	TypeReportShare      NotificationType = "report_share"
	TypeActionOverdue    NotificationType = "action_overdue"
	TypeStatusChanged    NotificationType = "status_changed"
)

type Notification struct {
	ID          uuid.UUID          `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	RecipientID uuid.UUID          `gorm:"type:uuid;not null"`
	Type        NotificationType   `gorm:"not null"`
	Subject     string             `gorm:"not null"`
	Body        string             `gorm:"not null"`
	Status      NotificationStatus `gorm:"type:notification_status;not null;default:pending"`
	SentAt      *time.Time
	Error       string
	CreatedAt   time.Time
}

func (Notification) TableName() string { return "notifications" }
