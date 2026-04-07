package request

// GenerateReportRequest triggers PDF generation for an inspection.
type GenerateReportRequest struct {
	InspectionID string `json:"inspection_id" binding:"required,uuid"`
}

// ShareReportRequest creates an expiring share link.
type ShareReportRequest struct {
	ExpiryHours int `json:"expiry_hours" binding:"required,min=1,max=720"` // max 30 days
}
