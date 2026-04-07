package request

// StartSessionRequest starts a new collaboration session for an inspection.
type StartSessionRequest struct {
	InspectionID string `json:"inspection_id" binding:"required,uuid"`
}

// EndSessionRequest ends an active session.
type EndSessionRequest struct {
	SessionID string `json:"session_id" binding:"required,uuid"`
}

type ShareInspectionRequest struct {
	UserID     string `json:"user_id" binding:"required,uuid"`
	Permission string `json:"permission" binding:"required,oneof=viewer editor reviewer"`
}
