package request

// UploadMediaRequest is sent as multipart/form-data.
// File is handled separately via c.FormFile("file").
type UploadMediaRequest struct {
	InspectionID string   `form:"inspection_id" binding:"required,uuid"`
	CapturedVia  string   `form:"captured_via"  binding:"required,oneof=camera gallery"`
	Latitude     *float64 `form:"latitude"      binding:"omitempty"`
	Longitude    *float64 `form:"longitude"     binding:"omitempty"`
	GPSSource    string   `form:"gps_source"    binding:"omitempty,oneof=device manual none"`
	CapturedAt   string   `form:"captured_at"   binding:"omitempty"` // RFC3339
}
