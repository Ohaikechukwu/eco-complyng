package response

import "time"

type NotificationResponse struct {
	ID          string     `json:"id"`
	RecipientID string     `json:"recipient_id"`
	Type        string     `json:"type"`
	Subject     string     `json:"subject"`
	Status      string     `json:"status"`
	SentAt      *time.Time `json:"sent_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}
