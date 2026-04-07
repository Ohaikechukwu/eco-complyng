package response

import "time"

type MediaResponse struct {
	ID           string    `json:"id"`
	InspectionID string    `json:"inspection_id"`
	UploadedBy   string    `json:"uploaded_by"`
	URL          string    `json:"url"`
	Filename     string    `json:"filename"`
	MimeType     string    `json:"mime_type"`
	SizeBytes    int64     `json:"size_bytes"`
	CapturedVia  string    `json:"captured_via"`
	Latitude     *float64  `json:"latitude,omitempty"`
	Longitude    *float64  `json:"longitude,omitempty"`
	GPSSource    string    `json:"gps_source"`
	CapturedAt   time.Time `json:"captured_at"`
	CreatedAt    time.Time `json:"created_at"`
}

type MediaListResponse struct {
	Media []MediaResponse `json:"media"`
	Total int64           `json:"total"`
}
