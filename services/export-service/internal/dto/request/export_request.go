package request

type CreateExportJobRequest struct {
	Type string `json:"type" binding:"required,oneof=db_backup report_batch media_export"`
}
