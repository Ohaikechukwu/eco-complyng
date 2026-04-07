package handler

import (
	"github.com/ecocomply/export-service/internal/dto/request"
	"github.com/ecocomply/export-service/internal/handler/middleware"
	"github.com/ecocomply/export-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type ExportHandler struct {
	svc *service.ExportService
}

func NewExportHandler(svc *service.ExportService) *ExportHandler {
	return &ExportHandler{svc: svc}
}

// POST /api/v1/exports
func (h *ExportHandler) CreateJob(c *gin.Context) {
	var req request.CreateExportJobRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	res, err := h.svc.CreateJob(c.Request.Context(), userID, orgSchema, req)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.Created(c, "export job queued", res)
}

// GET /api/v1/exports
func (h *ExportHandler) List(c *gin.Context) {
	res, total, err := h.svc.List(c.Request.Context(), 20, 0)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "export jobs retrieved", gin.H{"jobs": res, "total": total})
}
