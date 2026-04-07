package response

import "time"

type ReportResponse struct {
	ID            string     `json:"id"`
	InspectionID  string     `json:"inspection_id"`
	GeneratedBy   string     `json:"generated_by"`
	Status        string     `json:"status"`
	FileURL       string     `json:"file_url,omitempty"`
	FileSizeBytes int64      `json:"file_size_bytes,omitempty"`
	ShareToken    string     `json:"share_token,omitempty"`
	ShareExpiry   *time.Time `json:"share_expiry,omitempty"`
	ErrorMessage  string     `json:"error_message,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
}

type ShareLinkResponse struct {
	ShareURL   string    `json:"share_url"`
	ShareToken string    `json:"share_token"`
	ExpiresAt  time.Time `json:"expires_at"`
}
