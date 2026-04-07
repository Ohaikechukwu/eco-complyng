package domain

type EventType string

const (
	EventChecklistUpdate EventType = "checklist_update"
	EventCommentAdded    EventType = "comment_added"
	EventStatusChanged   EventType = "status_changed"
	EventActionCreated   EventType = "action_created"
	EventUserJoined      EventType = "user_joined"
	EventUserLeft        EventType = "user_left"
)

type WSEvent struct {
	Type    EventType   `json:"type"`
	Payload interface{} `json:"payload"`
	UserID  string      `json:"user_id"`
	OrgID   string      `json:"org_id"`
}
