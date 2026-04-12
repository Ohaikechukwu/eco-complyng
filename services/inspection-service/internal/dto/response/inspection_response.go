package response

import "time"

type InspectionResponse struct {
	ID             string    `json:"id"`
	ProjectName    string    `json:"project_name"`
	LocationName   string    `json:"location_name"`
	Latitude       *float64  `json:"latitude,omitempty"`
	Longitude      *float64  `json:"longitude,omitempty"`
	Date           time.Time `json:"date"`
	InspectorName  string    `json:"inspector_name"`
	InspectorRole  string    `json:"inspector_role"`
	AssignedUserID string    `json:"assigned_user_id"`
	ChecklistID    *string   `json:"checklist_id,omitempty"`
	Status         string    `json:"status"`
	Notes          string    `json:"notes,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`

	// Optional — loaded on detail view
	ChecklistItems []ChecklistItemResponse `json:"checklist_items,omitempty"`
	AgreedActions  []ActionResponse        `json:"agreed_actions,omitempty"`
	Comments       []CommentResponse       `json:"comments,omitempty"`
	Reviews        []ReviewResponse        `json:"reviews,omitempty"`

	// Summary counts for list view
	TotalItems     *int `json:"total_items,omitempty"`
	AnsweredItems  *int `json:"answered_items,omitempty"`
	PendingActions *int `json:"pending_actions,omitempty"`
}

type InspectionListResponse struct {
	Inspections []InspectionResponse `json:"inspections"`
	Total       int64                `json:"total"`
	Page        int                  `json:"page"`
	Limit       int                  `json:"limit"`
	TotalPages  int                  `json:"total_pages"`
}

type ChecklistItemResponse struct {
	ID          string `json:"id"`
	Description string `json:"description"`
	Response    *bool  `json:"response"`
	Comment     string `json:"comment,omitempty"`
	SortOrder   int    `json:"sort_order"`
}

type ActionResponse struct {
	ID          string     `json:"id"`
	Description string     `json:"description"`
	AssigneeID  string     `json:"assignee_id"`
	DueDate     time.Time  `json:"due_date"`
	Status      string     `json:"status"`
	EvidenceURL string     `json:"evidence_url,omitempty"`
	ResolvedAt  *time.Time `json:"resolved_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

type CommentResponse struct {
	ID        string    `json:"id"`
	AuthorID  string    `json:"author_id"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

type ReviewResponse struct {
	ID              string     `json:"id"`
	Stage           string     `json:"stage"`
	ReviewerID      string     `json:"reviewer_id"`
	AssignedToID    string     `json:"assigned_to_id"`
	Comment         string     `json:"comment"`
	DueDate         time.Time  `json:"due_date"`
	Status          string     `json:"status"`
	ResponseComment string     `json:"response_comment,omitempty"`
	ResolvedAt      *time.Time `json:"resolved_at,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
}

type ChecklistTemplateResponse struct {
	ID          string                 `json:"id"`
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	IsSystem    bool                   `json:"is_system"`
	CreatedBy   string                 `json:"created_by"`
	CreatedAt   time.Time              `json:"created_at"`
	Items       []TemplateItemResponse `json:"items,omitempty"`
}

type TemplateItemResponse struct {
	ID          string `json:"id"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
}

type DashboardResponse struct {
	Total          int64                `json:"total"`
	Draft          int64                `json:"draft"`
	InProgress     int64                `json:"in_progress"`
	Submitted      int64                `json:"submitted"`
	UnderReview    int64                `json:"under_review"`
	PendingActions int64                `json:"pending_actions"`
	Completed      int64                `json:"completed"`
	Finalized      int64                `json:"finalized"`
	Recent         []InspectionResponse `json:"recent"`
}

type AnalyticsResponse struct {
	StatusCounts           map[string]int64    `json:"status_counts"`
	ChecklistSummary       ChecklistSummary    `json:"checklist_summary"`
	ActionSummary          ActionSummary       `json:"action_summary"`
	InspectionLocations    []InspectionMapItem `json:"inspection_locations"`
	RecentPendingActionIDs []string            `json:"recent_pending_action_ids"`
}

type ChecklistSummary struct {
	Conformance    int64 `json:"conformance"`
	NonConformance int64 `json:"non_conformance"`
	Unanswered     int64 `json:"unanswered"`
}

type ActionSummary struct {
	Pending    int64 `json:"pending"`
	InProgress int64 `json:"in_progress"`
	Resolved   int64 `json:"resolved"`
	Overdue    int64 `json:"overdue"`
}

type InspectionMapItem struct {
	ID           string    `json:"id"`
	ProjectName  string    `json:"project_name"`
	LocationName string    `json:"location_name"`
	Latitude     *float64  `json:"latitude,omitempty"`
	Longitude    *float64  `json:"longitude,omitempty"`
	Status       string    `json:"status"`
	Date         time.Time `json:"date"`
}

type AnalyticsCompareResponse struct {
	CurrentPeriod  AnalyticsSnapshot `json:"current_period"`
	PreviousPeriod AnalyticsSnapshot `json:"previous_period"`
}

type AnalyticsSnapshot struct {
	From         time.Time        `json:"from"`
	To           time.Time        `json:"to"`
	StatusCounts map[string]int64 `json:"status_counts"`
	Total        int64            `json:"total"`
}

type GeoJSONResponse struct {
	Type     string           `json:"type"`
	Features []GeoJSONFeature `json:"features"`
}

type GeoJSONFeature struct {
	Type       string                 `json:"type"`
	Geometry   GeoJSONGeometry        `json:"geometry"`
	Properties map[string]interface{} `json:"properties"`
}

type GeoJSONGeometry struct {
	Type        string    `json:"type"`
	Coordinates []float64 `json:"coordinates"`
}

type SyncPullResponse struct {
	Inspections []InspectionResponse `json:"inspections"`
	DeletedIDs  []string             `json:"deleted_ids"`
	ServerTime  time.Time            `json:"server_time"`
}

type MergeConflictResponse struct {
	Message          string             `json:"message"`
	ServerInspection InspectionResponse `json:"server_inspection"`
}
