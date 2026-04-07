package request

// CreateActionRequest creates an agreed action on an inspection.
type CreateActionRequest struct {
	Description string `json:"description"  binding:"required"`
	AssigneeID  string `json:"assignee_id"  binding:"required,uuid"`
	DueDate     string `json:"due_date"     binding:"required"` // RFC3339
}

// UpdateActionRequest updates an action's status or evidence.
type UpdateActionRequest struct {
	Status      string `json:"status"       binding:"omitempty,oneof=pending in_progress resolved"`
	EvidenceURL string `json:"evidence_url"`
}

// AddCommentRequest adds a review comment to an inspection.
type AddCommentRequest struct {
	Body string `json:"body" binding:"required,min=1"`
}

type CreateReviewRequest struct {
	AssignedToID string `json:"assigned_to_id" binding:"required,uuid"`
	Comment      string `json:"comment" binding:"required,min=1"`
	DueDate      string `json:"due_date" binding:"required"`
}

type UpdateReviewRequest struct {
	Status          string `json:"status" binding:"required,oneof=addressed approved rejected"`
	ResponseComment string `json:"response_comment"`
}
