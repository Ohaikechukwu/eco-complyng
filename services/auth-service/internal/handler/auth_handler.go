package handler

import (
	"net/http"
	"time"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/ecocomply/auth-service/internal/dto/request"
	"github.com/ecocomply/auth-service/internal/handler/middleware"
	"github.com/ecocomply/auth-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"github.com/google/uuid"
)

type AuthHandler struct {
	svc *service.AuthService
}

func NewAuthHandler(svc *service.AuthService) *AuthHandler {
	return &AuthHandler{svc: svc}
}

func isMobile(c *gin.Context) bool {
	return c.GetHeader("X-Client-Type") == "mobile"
}

func (h *AuthHandler) RegisterOrg(c *gin.Context) {
	var req request.RegisterOrgRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.RegisterOrg(c.Request.Context(), req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.Created(c, "organisation registered successfully", res)
}

func (h *AuthHandler) Login(c *gin.Context) {
	var req request.LoginRequest
	if err := c.ShouldBindBodyWith(&req, binding.JSON); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	orgID, _ := uuid.Parse(c.GetString(middleware.ContextOrgID))
	res, err := h.svc.Login(c.Request.Context(), orgID, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}

	if isMobile(c) {
		response.OK(c, "login successful", res)
	} else {
		setAuthCookies(c, res.Tokens.AccessToken, res.Tokens.RefreshToken)
		response.OK(c, "login successful", gin.H{
			"user": res.User,
			"org":  res.Org,
		})
	}
}

func (h *AuthHandler) RefreshToken(c *gin.Context) {
	var rawRefreshToken string

	if isMobile(c) {
		var req request.RefreshTokenRequest
		if err := c.ShouldBindBodyWith(&req, binding.JSON); err != nil {
			response.BadRequest(c, err.Error())
			return
		}
		rawRefreshToken = req.RefreshToken
	} else {
		cookie, err := c.Cookie("refresh_token")
		if err != nil {
			response.Unauthorized(c, "missing refresh token")
			return
		}
		rawRefreshToken = cookie
	}

	tokens, err := h.svc.RefreshToken(c.Request.Context(), rawRefreshToken)
	if err != nil {
		response.Unauthorized(c, err.Error())
		return
	}

	if isMobile(c) {
		response.OK(c, "token refreshed", tokens)
	} else {
		setAuthCookies(c, tokens.AccessToken, tokens.RefreshToken)
		response.OK(c, "token refreshed", nil)
	}
}

func (h *AuthHandler) Logout(c *gin.Context) {
	tokenID, _ := c.Get("token_id")
	refreshToken, _ := c.Cookie("refresh_token")
	_ = h.svc.Logout(c.Request.Context(), tokenID.(string), refreshToken, 24*time.Hour)
	c.SetCookie("access_token", "", -1, "/", "", true, true)
	c.SetCookie("refresh_token", "", -1, "/", "", true, true)
	response.OK(c, "logged out successfully", nil)
}

func (h *AuthHandler) InviteUser(c *gin.Context) {
	var req request.InviteUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	inviterID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	orgName   := c.GetString(middleware.ContextOrgName)

	res, err := h.svc.InviteUser(c.Request.Context(), inviterID, orgSchema, orgName, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.Created(c, "user invited — they will receive an email with login instructions", res)
}

func (h *AuthHandler) UpdateRole(c *gin.Context) {
	var req request.UpdateRoleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid user id")
		return
	}
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	res, err := h.svc.UpdateRole(c.Request.Context(), userID, orgSchema, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "role updated", res)
}

func (h *AuthHandler) GetProfile(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	res, err := h.svc.GetProfile(c.Request.Context(), userID, orgSchema)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "profile retrieved", res)
}

func (h *AuthHandler) UpdateProfile(c *gin.Context) {
	var req request.UpdateProfileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	res, err := h.svc.UpdateProfile(c.Request.Context(), userID, orgSchema, req)
	if err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "profile updated", res)
}

func (h *AuthHandler) ChangePassword(c *gin.Context) {
	var req request.ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	if err := h.svc.ChangePassword(c.Request.Context(), userID, orgSchema, req); err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "password changed successfully", nil)
}

func (h *AuthHandler) ListUsers(c *gin.Context) {
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	users, total, err := h.svc.ListUsers(c.Request.Context(), orgSchema, 20, 0)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "users retrieved", gin.H{"users": users, "total": total})
}

func setAuthCookies(c *gin.Context, accessToken, refreshToken string) {
	secure := c.Request.TLS != nil
	c.SetCookie("access_token", accessToken, 3600*24, "/", "", secure, true)
	c.SetCookie("refresh_token", refreshToken, 3600*24*7, "/api/v1/auth/refresh", "", secure, true)
}

func handleServiceError(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrAlreadyExists:
		c.JSON(http.StatusConflict, gin.H{"success": false, "error": err.Error()})
	case domain.ErrUnauthorized, domain.ErrInvalidCredentials:
		response.Unauthorized(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrAccountInactive:
		response.Forbidden(c, err.Error())
	case domain.ErrTokenExpired, domain.ErrTokenInvalid:
		response.Unauthorized(c, err.Error())
	default:
		response.InternalError(c, "something went wrong")
	}
}

func (h *AuthHandler) ForgotPassword(c *gin.Context) {
	var req request.ForgotPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	if err := h.svc.ForgotPassword(c.Request.Context(), orgSchema, req); err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "if this email exists, a reset link has been sent", nil)
}

func (h *AuthHandler) ResetPassword(c *gin.Context) {
	var req request.ResetPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	if err := h.svc.ResetPassword(c.Request.Context(), req); err != nil {
		handleServiceError(c, err)
		return
	}
	response.OK(c, "password reset successfully", nil)
}
