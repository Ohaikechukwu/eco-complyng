package handler

import (
	"net/http"
	"time"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/ecocomply/inspection-service/internal/dto/request"
	"github.com/ecocomply/inspection-service/internal/handler/middleware"
	"github.com/ecocomply/inspection-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type InspectionHandler struct {
	svc *service.InspectionService
}

func NewInspectionHandler(svc *service.InspectionService) *InspectionHandler {
	return &InspectionHandler{svc: svc}
}

// GET /api/v1/inspections/dashboard
func (h *InspectionHandler) Dashboard(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	name := c.GetString(middleware.ContextUserName)

	res, err := h.svc.Dashboard(c.Request.Context(), userID, role, name, role)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "dashboard retrieved", res)
}

// GET /api/v1/inspections/analytics
func (h *InspectionHandler) Analytics(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)

	res, err := h.svc.Analytics(c.Request.Context(), userID, role)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "analytics retrieved", res)
}

func (h *InspectionHandler) AnalyticsCompare(c *gin.Context) {
	fromStr := c.Query("from")
	toStr := c.Query("to")
	if fromStr == "" || toStr == "" {
		response.BadRequest(c, "from and to are required")
		return
	}
	from, err := time.Parse(time.RFC3339, fromStr)
	if err != nil {
		response.BadRequest(c, "from must be RFC3339")
		return
	}
	to, err := time.Parse(time.RFC3339, toStr)
	if err != nil {
		response.BadRequest(c, "to must be RFC3339")
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	res, err := h.svc.AnalyticsCompare(c.Request.Context(), userID, role, from, to)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "analytics comparison retrieved", res)
}

func (h *InspectionHandler) AnalyticsGeoJSON(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	res, err := h.svc.AnalyticsGeoJSON(c.Request.Context(), userID, role)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "geojson retrieved", res)
}

func (h *InspectionHandler) SyncPull(c *gin.Context) {
	sinceStr := c.Query("since")
	if sinceStr == "" {
		response.BadRequest(c, "since is required")
		return
	}
	since, err := time.Parse(time.RFC3339, sinceStr)
	if err != nil {
		response.BadRequest(c, "since must be RFC3339")
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	res, err := h.svc.SyncPull(c.Request.Context(), since, userID, role)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "sync payload retrieved", res)
}

// GET /api/v1/inspections
func (h *InspectionHandler) List(c *gin.Context) {
	var req request.ListInspectionsRequest
	if err := c.ShouldBindQuery(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)

	res, err := h.svc.List(c.Request.Context(), userID, role, req)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "inspections retrieved", res)
}

// POST /api/v1/inspections
func (h *InspectionHandler) Create(c *gin.Context) {
	var req request.CreateInspectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	name := c.GetString(middleware.ContextUserName)
	role := c.GetString(middleware.ContextRole)

	res, err := h.svc.Create(c.Request.Context(), userID, name, role, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "inspection created", res)
}

// GET /api/v1/inspections/:id
func (h *InspectionHandler) GetByID(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	res, err := h.svc.GetByID(c.Request.Context(), id)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "inspection retrieved", res)
}

// PATCH /api/v1/inspections/:id
func (h *InspectionHandler) Update(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.UpdateInspectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.Update(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "inspection updated", res)
}

func (h *InspectionHandler) OfflineMerge(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.OfflineMergeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, conflict, err := h.svc.OfflineMerge(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	if conflict != nil {
		c.JSON(http.StatusConflict, gin.H{"success": false, "error": conflict.Message, "data": conflict})
		return
	}
	response.OK(c, "inspection merged", res)
}

// PATCH /api/v1/inspections/:id/status
func (h *InspectionHandler) TransitionStatus(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.TransitionStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.TransitionStatus(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "status updated", res)
}

// DELETE /api/v1/inspections/:id
func (h *InspectionHandler) Delete(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	if err := h.svc.Delete(c.Request.Context(), id); err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "inspection deleted", nil)
}

// POST /api/v1/inspections/:id/checklist
func (h *InspectionHandler) AddChecklistItem(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.AddChecklistItemRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.AddChecklistItem(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "checklist item added", res)
}

// PATCH /api/v1/inspections/:id/checklist/:itemId
func (h *InspectionHandler) UpdateChecklistItem(c *gin.Context) {
	itemID, err := uuid.Parse(c.Param("itemId"))
	if err != nil {
		response.BadRequest(c, "invalid item id")
		return
	}
	var req request.UpdateChecklistItemRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.UpdateChecklistItem(c.Request.Context(), itemID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "checklist item updated", res)
}

// POST /api/v1/inspections/:id/actions
func (h *InspectionHandler) CreateAction(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.CreateActionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	createdBy, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.CreateAction(c.Request.Context(), id, createdBy, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "action created", res)
}

// PATCH /api/v1/inspections/:id/actions/:actionId
func (h *InspectionHandler) UpdateAction(c *gin.Context) {
	actionID, err := uuid.Parse(c.Param("actionId"))
	if err != nil {
		response.BadRequest(c, "invalid action id")
		return
	}
	var req request.UpdateActionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.UpdateAction(c.Request.Context(), actionID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "action updated", res)
}

// POST /api/v1/inspections/:id/comments
func (h *InspectionHandler) AddComment(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.AddCommentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	authorID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.AddComment(c.Request.Context(), id, authorID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "comment added", res)
}

func (h *InspectionHandler) CreateReview(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.CreateReviewRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	reviewerID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	res, err := h.svc.CreateReview(c.Request.Context(), id, reviewerID, role, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "review created", res)
}

func (h *InspectionHandler) UpdateReview(c *gin.Context) {
	reviewID, err := uuid.Parse(c.Param("reviewId"))
	if err != nil {
		response.BadRequest(c, "invalid review id")
		return
	}
	var req request.UpdateReviewRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	res, err := h.svc.UpdateReview(c.Request.Context(), reviewID, userID, role, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "review updated", res)
}

// GET /api/v1/inspections/templates
func (h *InspectionHandler) ListTemplates(c *gin.Context) {
	res, err := h.svc.ListTemplates(c.Request.Context())
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "templates retrieved", res)
}

// POST /api/v1/inspections/templates
func (h *InspectionHandler) CreateTemplate(c *gin.Context) {
	var req request.CreateTemplateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.CreateTemplate(c.Request.Context(), userID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "template created", res)
}

func handleErr(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput:
		response.BadRequest(c, err.Error())
	case domain.ErrInvalidTransition:
		c.JSON(http.StatusUnprocessableEntity, gin.H{"success": false, "error": err.Error()})
	default:
		response.InternalError(c, "something went wrong")
	}
}
