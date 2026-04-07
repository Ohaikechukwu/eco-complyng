package request

// CreateInspectionRequest creates a new inspection.
type CreateInspectionRequest struct {
	ProjectName  string   `json:"project_name"  binding:"required,min=2,max=200"`
	LocationName string   `json:"location_name"`
	Latitude     *float64 `json:"latitude"`
	Longitude    *float64 `json:"longitude"`
	ChecklistID  string   `json:"checklist_id"` // optional — links a template
	Notes        string   `json:"notes"`
}

// UpdateInspectionRequest updates editable fields on a draft inspection.
type UpdateInspectionRequest struct {
	ProjectName  string   `json:"project_name"  binding:"omitempty,min=2,max=200"`
	LocationName string   `json:"location_name"`
	Latitude     *float64 `json:"latitude"`
	Longitude    *float64 `json:"longitude"`
	Notes        string   `json:"notes"`
}

// TransitionStatusRequest moves an inspection to the next status.
type TransitionStatusRequest struct {
	Status string `json:"status" binding:"required"`
}

// ListInspectionsRequest holds query params for the inspection list.
type ListInspectionsRequest struct {
	Status string `form:"status"`
	Search string `form:"search"`
	Page   int    `form:"page,default=1"`
	Limit  int    `form:"limit,default=20"`
}

type SyncPullRequest struct {
	Since string `form:"since" binding:"required"`
}

type OfflineMergeRequest struct {
	ClientUpdatedAt string   `json:"client_updated_at" binding:"required"`
	ProjectName     string   `json:"project_name"`
	LocationName    string   `json:"location_name"`
	Latitude        *float64 `json:"latitude"`
	Longitude       *float64 `json:"longitude"`
	Notes           string   `json:"notes"`
	Status          string   `json:"status"`
}
