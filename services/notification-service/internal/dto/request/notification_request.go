package request

type SendNotificationRequest struct {
	RecipientID string `json:"recipient_id" binding:"required,uuid"`
	Type        string `json:"type"         binding:"required"`
	Subject     string `json:"subject"      binding:"required"`
	Body        string `json:"body"         binding:"required"`
}

type SendEmailRequest struct {
	To      string `json:"to"      binding:"required,email"`
	Subject string `json:"subject" binding:"required"`
	Body    string `json:"body"    binding:"required"`
}
