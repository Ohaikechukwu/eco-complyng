package handler

import (
	"github.com/ecocomply/collaboration-service/internal/dto/request"
	"github.com/ecocomply/collaboration-service/internal/handler/middleware"
	"github.com/ecocomply/collaboration-service/internal/service"
	"github.com/ecocomply/collaboration-service/internal/ws"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type CollabHandler struct {
	svc *service.CollabService
	hub *ws.Hub
}

func NewCollabHandler(svc *service.CollabService, hub *ws.Hub) *CollabHandler {
	return &CollabHandler{svc: svc, hub: hub}
}

// GET /api/v1/collaborate/:inspection_id/ws
func (h *CollabHandler) ServeWS(c *gin.Context) {
	inspectionID := c.Param("inspection_id")
	userID := c.GetString(middleware.ContextUserID)
	if inspectionID == "" || userID == "" {
		response.Unauthorized(c, "missing collaboration context")
		return
	}

	inspectionUUID, err := uuid.Parse(inspectionID)
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	userUUID, err := uuid.Parse(userID)
	if err != nil {
		response.BadRequest(c, "invalid user id")
		return
	}
	if err := h.svc.EnsureAccess(c.Request.Context(), inspectionUUID, userUUID); err != nil {
		response.Forbidden(c, "you do not have collaboration access")
		return
	}

	conn, err := ws.Upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		response.InternalError(c, "websocket upgrade failed")
		return
	}

	client := ws.NewClient(h.hub, conn, inspectionID, userID)
	h.hub.Join(client)

	go client.WritePump()
	go client.ReadPump()
}

func (h *CollabHandler) Share(c *gin.Context) {
	inspectionID, err := uuid.Parse(c.Param("inspection_id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.ShareInspectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	invitedBy, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.ShareInspection(c.Request.Context(), inspectionID, invitedBy, req)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.Created(c, "inspection shared", res)
}

func (h *CollabHandler) ListAccess(c *gin.Context) {
	inspectionID, err := uuid.Parse(c.Param("inspection_id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	res, err := h.svc.ListAccess(c.Request.Context(), inspectionID)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "collaboration access retrieved", res)
}

func (h *CollabHandler) Revoke(c *gin.Context) {
	inspectionID, err := uuid.Parse(c.Param("inspection_id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	userID, err := uuid.Parse(c.Param("user_id"))
	if err != nil {
		response.BadRequest(c, "invalid user id")
		return
	}
	if err := h.svc.RevokeAccess(c.Request.Context(), inspectionID, userID); err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "collaboration access revoked", nil)
}
