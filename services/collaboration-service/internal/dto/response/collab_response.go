package response

import "time"

type SessionResponse struct {
	ID           string                `json:"id"`
	InspectionID string                `json:"inspection_id"`
	IsActive     bool                  `json:"is_active"`
	Participants []ParticipantResponse `json:"participants"`
	CreatedAt    time.Time             `json:"created_at"`
}

type ParticipantResponse struct {
	UserID   string     `json:"user_id"`
	JoinedAt time.Time  `json:"joined_at"`
	LeftAt   *time.Time `json:"left_at,omitempty"`
}

type RoomStatusResponse struct {
	RoomID       string `json:"room_id"`
	Participants int    `json:"participants"`
	IsActive     bool   `json:"is_active"`
}

type AccessResponse struct {
	ID           string    `json:"id"`
	InspectionID string    `json:"inspection_id"`
	UserID       string    `json:"user_id"`
	Permission   string    `json:"permission"`
	Status       string    `json:"status"`
	InvitedBy    string    `json:"invited_by"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}
