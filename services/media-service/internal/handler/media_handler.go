package handler

import (
	"github.com/ecocomply/media-service/internal/domain"
	"github.com/ecocomply/media-service/internal/dto/request"
	"github.com/ecocomply/media-service/internal/handler/middleware"
	"github.com/ecocomply/media-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type MediaHandler struct {
	svc *service.MediaService
}

func NewMediaHandler(svc *service.MediaService) *MediaHandler {
	return &MediaHandler{svc: svc}
}

// POST /api/v1/media  (multipart/form-data)
func (h *MediaHandler) Upload(c *gin.Context) {
	var req request.UploadMediaRequest
	if err := c.ShouldBind(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	fileHeader, err := c.FormFile("file")
	if err != nil {
		response.BadRequest(c, "file is required")
		return
	}

	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.Upload(c.Request.Context(), userID, fileHeader, req)
	if err != nil {
		handleError(c, err)
		return
	}

	response.Created(c, "media uploaded", res)
}

// GET /api/v1/media?inspection_id=xxx
func (h *MediaHandler) GetByInspection(c *gin.Context) {
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

	response.OK(c, "media retrieved", res)
}

// DELETE /api/v1/media/:id
func (h *MediaHandler) Delete(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid media id")
		return
	}

	if err := h.svc.Delete(c.Request.Context(), id); err != nil {
		handleError(c, err)
		return
	}

	response.OK(c, "media deleted", nil)
}

func handleError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput, domain.ErrUnsupportedType:
		response.BadRequest(c, err.Error())
	case domain.ErrFileTooLarge:
		c.JSON(413, gin.H{"success": false, "error": err.Error()})
	default:
		response.InternalError(c, "something went wrong")
	}
}
