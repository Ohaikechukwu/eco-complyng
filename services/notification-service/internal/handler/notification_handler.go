package handler

import (
	"github.com/ecocomply/notification-service/internal/dto/request"
	"github.com/ecocomply/notification-service/internal/handler/middleware"
	"github.com/ecocomply/notification-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type NotificationHandler struct {
	svc *service.NotificationService
}

func NewNotificationHandler(svc *service.NotificationService) *NotificationHandler {
	return &NotificationHandler{svc: svc}
}

// GET /api/v1/notifications
func (h *NotificationHandler) List(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, total, err := h.svc.GetByRecipient(c.Request.Context(), userID, 20, 0)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "notifications retrieved", gin.H{"notifications": res, "total": total})
}

// POST /api/v1/notifications/email
func (h *NotificationHandler) SendEmail(c *gin.Context) {
	var req request.SendEmailRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	if err := h.svc.SendEmail(c.Request.Context(), req); err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "email queued", nil)
}
