package handler

import (
	"crypto/rand"
	"encoding/hex"
	"net"
	"net/http"
	"net/url"
	"strings"
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
	svc          *service.AuthService
	cookieConfig CookieConfig
}

type CookieConfig struct {
	Domain            string
	Secure            bool
	SameSite          http.SameSite
	AccessCookieName  string
	RefreshCookieName string
	CSRFCookieName    string
	AccessCookiePath  string
	RefreshCookiePath string
	CSRFCookiePath    string
	AccessMaxAge      time.Duration
	RefreshMaxAge     time.Duration
}

func ParseSameSite(value string) http.SameSite {
	switch value {
	case "Strict", "strict":
		return http.SameSiteStrictMode
	case "None", "none":
		return http.SameSiteNoneMode
	default:
		return http.SameSiteLaxMode
	}
}

func NewAuthHandler(svc *service.AuthService, cookieConfig CookieConfig) *AuthHandler {
	return &AuthHandler{svc: svc, cookieConfig: cookieConfig}
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
		h.setAuthCookies(c, res.Tokens.AccessToken, res.Tokens.RefreshToken)
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
		h.setAuthCookies(c, tokens.AccessToken, tokens.RefreshToken)
		response.OK(c, "token refreshed", nil)
	}
}

func (h *AuthHandler) Logout(c *gin.Context) {
	var tokenID string
	if value, ok := c.Get(middleware.ContextTokenID); ok {
		tokenID, _ = value.(string)
	}

	var accessExpiresAt time.Time
	if value, ok := c.Get(middleware.ContextTokenExpiry); ok {
		if expiry, ok := value.(time.Time); ok {
			accessExpiresAt = expiry
		}
	}

	refreshToken, _ := c.Cookie(h.cookieConfig.RefreshCookieName)
	orgSchema := c.GetString(middleware.ContextOrgSchema)
	_ = h.svc.Logout(c.Request.Context(), tokenID, accessExpiresAt, refreshToken, orgSchema)
	h.clearAuthCookies(c)
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
	orgName := c.GetString(middleware.ContextOrgName)

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

func (h *AuthHandler) setAuthCookies(c *gin.Context, accessToken, refreshToken string) {
	secure, sameSite := h.resolveCookiePolicy(c)

	http.SetCookie(c.Writer, &http.Cookie{
		Name:     h.cookieConfig.AccessCookieName,
		Value:    accessToken,
		Path:     h.cookieConfig.AccessCookiePath,
		Domain:   h.cookieConfig.Domain,
		MaxAge:   int(h.cookieConfig.AccessMaxAge.Seconds()),
		HttpOnly: true,
		Secure:   secure,
		SameSite: sameSite,
	})
	http.SetCookie(c.Writer, &http.Cookie{
		Name:     h.cookieConfig.RefreshCookieName,
		Value:    refreshToken,
		Path:     h.cookieConfig.RefreshCookiePath,
		Domain:   h.cookieConfig.Domain,
		MaxAge:   int(h.cookieConfig.RefreshMaxAge.Seconds()),
		HttpOnly: true,
		Secure:   secure,
		SameSite: sameSite,
	})
	http.SetCookie(c.Writer, &http.Cookie{
		Name:     h.cookieConfig.CSRFCookieName,
		Value:    generateCSRFToken(),
		Path:     h.cookieConfig.CSRFCookiePath,
		Domain:   h.cookieConfig.Domain,
		MaxAge:   int(h.cookieConfig.RefreshMaxAge.Seconds()),
		HttpOnly: false,
		Secure:   secure,
		SameSite: sameSite,
	})
}

func generateCSRFToken() string {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return ""
	}
	return hex.EncodeToString(buf)
}

func (h *AuthHandler) clearAuthCookies(c *gin.Context) {
	secure, sameSite := h.resolveCookiePolicy(c)

	http.SetCookie(c.Writer, &http.Cookie{
		Name:     h.cookieConfig.AccessCookieName,
		Value:    "",
		Path:     h.cookieConfig.AccessCookiePath,
		Domain:   h.cookieConfig.Domain,
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   secure,
		SameSite: sameSite,
	})
	http.SetCookie(c.Writer, &http.Cookie{
		Name:     h.cookieConfig.RefreshCookieName,
		Value:    "",
		Path:     h.cookieConfig.RefreshCookiePath,
		Domain:   h.cookieConfig.Domain,
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   secure,
		SameSite: sameSite,
	})
	http.SetCookie(c.Writer, &http.Cookie{
		Name:     h.cookieConfig.CSRFCookieName,
		Value:    "",
		Path:     h.cookieConfig.CSRFCookiePath,
		Domain:   h.cookieConfig.Domain,
		MaxAge:   -1,
		HttpOnly: false,
		Secure:   secure,
		SameSite: sameSite,
	})
}

func (h *AuthHandler) resolveCookiePolicy(c *gin.Context) (bool, http.SameSite) {
	secure := h.cookieConfig.Secure || requestIsHTTPS(c)
	sameSite := h.cookieConfig.SameSite

	if requestIsCrossOrigin(c) {
		if isLocalDevRequest(c) {
			return secure, sameSite
		}

		// Cross-origin XHR/fetch requests need SameSite=None and Secure for browsers
		// to store and send auth cookies consistently.
		sameSite = http.SameSiteNoneMode
		secure = true
	}

	return secure, sameSite
}

func requestIsHTTPS(c *gin.Context) bool {
	if c.Request.TLS != nil {
		return true
	}

	if strings.EqualFold(strings.TrimSpace(c.GetHeader("X-Forwarded-Proto")), "https") {
		return true
	}

	return strings.EqualFold(strings.TrimSpace(c.GetHeader("X-Forwarded-Ssl")), "on")
}

func requestIsCrossOrigin(c *gin.Context) bool {
	originHeader := strings.TrimSpace(c.GetHeader("Origin"))
	if originHeader == "" {
		return false
	}

	originURL, err := url.Parse(originHeader)
	if err != nil || originURL.Host == "" {
		return false
	}

	requestHost := strings.TrimSpace(c.Request.Host)
	if requestHost == "" {
		requestHost = strings.TrimSpace(c.GetHeader("X-Forwarded-Host"))
	}
	if requestHost == "" {
		return false
	}

	originHost := stripPort(originURL.Host)
	currentHost := stripPort(requestHost)

	return !strings.EqualFold(originHost, currentHost)
}

func stripPort(host string) string {
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		return parsedHost
	}
	return host
}

func isLocalDevRequest(c *gin.Context) bool {
	originHeader := strings.TrimSpace(c.GetHeader("Origin"))
	if originHeader == "" {
		return false
	}

	originURL, err := url.Parse(originHeader)
	if err != nil {
		return false
	}

	requestHost := strings.TrimSpace(c.Request.Host)
	if requestHost == "" {
		requestHost = strings.TrimSpace(c.GetHeader("X-Forwarded-Host"))
	}
	if requestHost == "" {
		return false
	}

	return isLoopbackHost(stripPort(originURL.Host)) && isLoopbackHost(stripPort(requestHost)) && !requestIsHTTPS(c)
}

func isLoopbackHost(host string) bool {
	normalized := strings.TrimSpace(strings.ToLower(host))
	switch normalized {
	case "localhost", "127.0.0.1", "::1":
		return true
	}

	ip := net.ParseIP(normalized)
	return ip != nil && ip.IsLoopback()
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
