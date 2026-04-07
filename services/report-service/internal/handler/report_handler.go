package handler

import (
	"github.com/ecocomply/report-service/internal/domain"
	"github.com/ecocomply/report-service/internal/dto/request"
	"github.com/ecocomply/report-service/internal/handler/middleware"
	"github.com/ecocomply/report-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type ReportHandler struct {
	svc *service.ReportService
}

func NewReportHandler(svc *service.ReportService) *ReportHandler {
	return &ReportHandler{svc: svc}
}

// POST /api/v1/reports/generate
func (h *ReportHandler) Generate(c *gin.Context) {
	var req request.GenerateReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	accessToken := middleware.ExtractToken(c)

	res, err := h.svc.Generate(c.Request.Context(), userID, accessToken, req)
	if err != nil {
		handleError(c, err)
		return
	}
	response.Created(c, "report generation started", res)
}

// GET /api/v1/reports?inspection_id=xxx
func (h *ReportHandler) GetByInspection(c *gin.Context) {
	inspectionIDStr := c.Query("inspection_id")
	if inspectionIDStr == "" {
		response.BadRequest(c, "inspection_id is required")
		return
	}
	inspectionID, err := uuid.Parse(inspectionIDStr)
	if err != nil {
		response.BadRequest(c, "invalid inspection_id")
		return
	}
	res, err := h.svc.GetByInspection(c.Request.Context(), inspectionID)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "reports retrieved", res)
}

// GET /api/v1/reports/:id
func (h *ReportHandler) GetByID(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid report id")
		return
	}
	res, err := h.svc.GetByID(c.Request.Context(), id)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "report retrieved", res)
}

// POST /api/v1/reports/:id/share
func (h *ReportHandler) CreateShareLink(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid report id")
		return
	}
	var req request.ShareReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.CreateShareLink(c.Request.Context(), id, req)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "share link created", res)
}

// GET /api/v1/reports/share/:token  (public — no auth required)
func (h *ReportHandler) GetByShareToken(c *gin.Context) {
	token := c.Param("token")
	res, err := h.svc.GetByShareToken(c.Request.Context(), token)
	if err != nil {
		handleError(c, err)
		return
	}
	response.OK(c, "report retrieved", res)
}

func handleError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput:
		response.BadRequest(c, err.Error())
	case domain.ErrShareExpired:
		response.BadRequest(c, err.Error())
	case domain.ErrReportNotReady:
		c.JSON(202, gin.H{"success": false, "error": err.Error()})
	default:
		response.InternalError(c, "something went wrong")
	}
}
