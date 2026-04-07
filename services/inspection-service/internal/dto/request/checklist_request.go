package request

// CreateTemplateRequest creates a new checklist template.
type CreateTemplateRequest struct {
	Name        string                      `json:"name"        binding:"required,min=2,max=200"`
	Description string                      `json:"description"`
	Items       []CreateTemplateItemRequest `json:"items" binding:"required,min=1,dive"`
}

type CreateTemplateItemRequest struct {
	Description string `json:"description" binding:"required"`
	SortOrder   int    `json:"sort_order"`
}

// CloneTemplateRequest clones a system template into the org's schema.
type CloneTemplateRequest struct {
	SystemTemplateID string `json:"system_template_id" binding:"required,uuid"`
	Name             string `json:"name"               binding:"omitempty,min=2,max=200"`
}

// UpdateChecklistItemRequest responds to a single checklist item.
type UpdateChecklistItemRequest struct {
	Response *bool  `json:"response"` // true=yes, false=no, null=unanswered
	Comment  string `json:"comment"`
}

// AddChecklistItemRequest adds an ad-hoc item to an inspection.
type AddChecklistItemRequest struct {
	Description string `json:"description" binding:"required"`
	SortOrder   int    `json:"sort_order"`
}
