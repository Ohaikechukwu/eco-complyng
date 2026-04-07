#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — Complete invite user flow
# Run from inside ~/ecocomply-ng:
#   chmod +x fix_invite_flow.sh && ./fix_invite_flow.sh
# =============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# 1. ADD must_change_password TO USER DOMAIN
# =============================================================================
info "Updating user domain..."

cat > services/auth-service/internal/domain/user.go << 'EOF'
package domain

import (
	"time"
	"github.com/google/uuid"
)

type Role string

const (
	RoleOrgAdmin   Role = "org_admin"
	RoleManager    Role = "manager"
	RoleSupervisor Role = "supervisor"
	RoleEnumerator Role = "enumerator"
)

type User struct {
	ID                 uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Name               string     `gorm:"not null"`
	Email              string     `gorm:"uniqueIndex;not null"`
	PasswordHash       string     `gorm:"not null"`
	Role               Role       `gorm:"type:user_role;not null;default:enumerator"`
	IsActive           bool       `gorm:"not null;default:true"`
	MustChangePassword bool       `gorm:"not null;default:false"`
	InvitedBy          *uuid.UUID `gorm:"type:uuid"`
	LastLoginAt        *time.Time
	CreatedAt          time.Time
	UpdatedAt          time.Time
	DeletedAt          *time.Time `gorm:"index"`
}

func (User) TableName() string { return "users" }
EOF

log "User domain updated"

# =============================================================================
# 2. UPDATE USER RESPONSE DTO
# =============================================================================
info "Updating user response DTO..."

cat > services/auth-service/internal/dto/response/auth_response.go << 'EOF'
package response

import "time"

type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresAt    int64  `json:"expires_at"`
}

type UserResponse struct {
	ID                 string     `json:"id"`
	Name               string     `json:"name"`
	Email              string     `json:"email"`
	Role               string     `json:"role"`
	IsActive           bool       `json:"is_active"`
	MustChangePassword bool       `json:"must_change_password"`
	LastLoginAt        *time.Time `json:"last_login_at,omitempty"`
	CreatedAt          time.Time  `json:"created_at"`
}

type OrgResponse struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	SchemaName string    `json:"schema_name"`
	Email      string    `json:"email"`
	IsActive   bool      `json:"is_active"`
	CreatedAt  time.Time `json:"created_at"`
}

type LoginResponse struct {
	Tokens TokenPair    `json:"tokens"`
	User   UserResponse `json:"user"`
	Org    OrgResponse  `json:"org"`
}

type RegisterOrgResponse struct {
	Org  OrgResponse  `json:"org"`
	User UserResponse `json:"user"`
}
EOF

log "DTO updated"

# =============================================================================
# 3. NOTIFICATION CLIENT
# =============================================================================
info "Writing notification client..."

cat > services/auth-service/internal/service/notification_client.go << 'EOF'
package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type NotificationClient struct {
	baseURL    string
	httpClient *http.Client
}

func NewNotificationClient(baseURL string) *NotificationClient {
	return &NotificationClient{
		baseURL:    baseURL,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

type sendEmailRequest struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
}

func (n *NotificationClient) SendInviteEmail(ctx context.Context, toEmail, name, orgName, role, tempPassword, loginURL string) error {
	body := fmt.Sprintf(`Hi %s,

You have been invited to join %s on EcoComply NG as a %s.

Your login details:
  Email:    %s
  Password: %s

Please log in at %s and change your password immediately after signing in.

This is an automated message from EcoComply NG.`, name, orgName, role, toEmail, tempPassword, loginURL)

	payload := sendEmailRequest{
		To:      toEmail,
		Subject: fmt.Sprintf("You've been invited to join %s on EcoComply NG", orgName),
		Body:    body,
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		n.baseURL+"/api/v1/notifications/email", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := n.httpClient.Do(req)
	if err != nil {
		// Don't fail the invite if notification service is down
		fmt.Printf("WARNING: notification service unreachable: %v\n", err)
		return nil
	}
	defer resp.Body.Close()
	return nil
}
EOF

log "Notification client written"

# =============================================================================
# 4. UPDATE CONFIG
# =============================================================================
info "Updating config..."

cat > services/auth-service/internal/config/config.go << 'EOF'
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env                    string
	Port                   string
	GRPCPort               string
	DBHost                 string
	DBPort                 string
	DBName                 string
	DBUser                 string
	DBPassword             string
	RedisHost              string
	RedisPort              string
	RedisPass              string
	JWTSecret              string
	JWTExpiryHrs           int
	NotificationServiceURL string
	AppBaseURL             string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env:                    getEnv("ENV", "development"),
		Port:                   getEnv("PORT", "8081"),
		GRPCPort:               getEnv("GRPC_PORT", "50051"),
		DBHost:                 getEnv("DB_HOST", "localhost"),
		DBPort:                 getEnv("DB_PORT", "5432"),
		DBName:                 getEnv("DB_NAME", "ecocomply"),
		DBUser:                 getEnv("DB_USER", "postgres"),
		DBPassword:             getEnv("DB_PASSWORD", "secret"),
		RedisHost:              getEnv("REDIS_HOST", "localhost"),
		RedisPort:              getEnv("REDIS_PORT", "6379"),
		RedisPass:              getEnv("REDIS_PASS", ""),
		JWTSecret:              getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs:           expiry,
		NotificationServiceURL: getEnv("NOTIFICATION_SERVICE_URL", "http://notification-service:8086"),
		AppBaseURL:             getEnv("APP_BASE_URL", "http://localhost:3000"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF

# Add to .env
echo "NOTIFICATION_SERVICE_URL=http://notification-service:8086" >> services/auth-service/.env
echo "APP_BASE_URL=http://localhost:3000" >> services/auth-service/.env

log "Config updated"

# =============================================================================
# 5. UPDATE AUTH SERVICE — full replacement with invite email + must_change_password
# =============================================================================
info "Updating auth service..."

cat > services/auth-service/internal/service/auth_service.go << 'EOF'
package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/ecocomply/auth-service/internal/domain"
	"github.com/ecocomply/auth-service/internal/dto/request"
	"github.com/ecocomply/auth-service/internal/dto/response"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/postgres"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

type AuthService struct {
	dbCfg                  sharedpostgres.Config
	db                     *gorm.DB
	userRepo               irepository.UserRepository
	orgRepo                irepository.OrgRepository
	tokenRepo              irepository.TokenRepository
	tokenCache             *cache.TokenCache
	jwt                    *sharedjwt.Manager
	notificationClient     *NotificationClient
	appBaseURL             string
}

func NewAuthService(
	dbCfg sharedpostgres.Config,
	db *gorm.DB,
	userRepo irepository.UserRepository,
	orgRepo irepository.OrgRepository,
	tokenRepo irepository.TokenRepository,
	tokenCache *cache.TokenCache,
	jwt *sharedjwt.Manager,
	notificationClient *NotificationClient,
	appBaseURL string,
) *AuthService {
	return &AuthService{
		dbCfg:              dbCfg,
		db:                 db,
		userRepo:           userRepo,
		orgRepo:            orgRepo,
		tokenRepo:          tokenRepo,
		tokenCache:         tokenCache,
		jwt:                jwt,
		notificationClient: notificationClient,
		appBaseURL:         appBaseURL,
	}
}

func (s *AuthService) tenantDB(schema string) (*gorm.DB, error) {
	return sharedpostgres.ConnectWithSchema(s.dbCfg, schema)
}

func (s *AuthService) RegisterOrg(ctx context.Context, req request.RegisterOrgRequest) (*response.RegisterOrgResponse, error) {
	_, err := s.orgRepo.FindByEmail(ctx, req.Email)
	if err == nil {
		return nil, domain.ErrAlreadyExists
	}
	if !errors.Is(err, domain.ErrNotFound) {
		return nil, err
	}

	schemaName := domain.SchemaNameFrom(req.OrgName)
	org := &domain.Org{
		Name:       req.OrgName,
		SchemaName: schemaName,
		Email:      req.Email,
		IsActive:   true,
	}

	if err := s.orgRepo.Create(ctx, org); err != nil {
		return nil, err
	}

	if err := s.orgRepo.ProvisionSchema(ctx, schemaName); err != nil {
		return nil, fmt.Errorf("schema provisioning failed: %w", err)
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}

	admin := &domain.User{
		Name:               req.Name,
		Email:              req.Email,
		PasswordHash:       string(hash),
		Role:               domain.RoleOrgAdmin,
		IsActive:           true,
		MustChangePassword: false,
	}

	tdb, err := s.tenantDB(schemaName)
	if err != nil {
		return nil, fmt.Errorf("tenant db connection failed: %w", err)
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	if err := tenantUserRepo.Create(ctx, admin); err != nil {
		return nil, err
	}

	_ = s.tokenCache.CacheOrgSchema(ctx, org.ID.String(), schemaName)

	return &response.RegisterOrgResponse{
		Org:  toOrgResponse(org),
		User: toUserResponse(admin),
	}, nil
}

func (s *AuthService) Login(ctx context.Context, orgID uuid.UUID, req request.LoginRequest) (*response.LoginResponse, error) {
	org, err := s.orgRepo.FindByID(ctx, orgID)
	if err != nil {
		return nil, err
	}

	tdb, err := s.tenantDB(org.SchemaName)
	if err != nil {
		return nil, err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)

	user, err := tenantUserRepo.FindByEmail(ctx, req.Email)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			return nil, domain.ErrInvalidCredentials
		}
		return nil, err
	}

	if !user.IsActive {
		return nil, domain.ErrAccountInactive
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		return nil, domain.ErrInvalidCredentials
	}

	tokens, err := s.issueTokenPair(ctx, user, org, tdb)
	if err != nil {
		return nil, err
	}

	now := time.Now()
	user.LastLoginAt = &now
	_ = tenantUserRepo.Update(ctx, user)

	return &response.LoginResponse{
		Tokens: *tokens,
		User:   toUserResponse(user),
		Org:    toOrgResponse(org),
	}, nil
}

func (s *AuthService) RefreshToken(ctx context.Context, orgID uuid.UUID, rawToken string) (*response.TokenPair, error) {
	tokenHash := hashToken(rawToken)

	org, err := s.orgRepo.FindByID(ctx, orgID)
	if err != nil {
		return nil, err
	}

	tdb, err := s.tenantDB(org.SchemaName)
	if err != nil {
		return nil, err
	}

	tenantTokenRepo := postgres.NewTokenRepository(tdb)
	userID, _, err := tenantTokenRepo.FindRefreshToken(ctx, tokenHash)
	if err != nil {
		return nil, domain.ErrTokenInvalid
	}
	_ = tenantTokenRepo.RevokeRefreshToken(ctx, tokenHash)

	tenantUserRepo := postgres.NewUserRepository(tdb)
	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	return s.issueTokenPair(ctx, user, org, tdb)
}

func (s *AuthService) Logout(ctx context.Context, tokenID string, rawRefreshToken string, ttl time.Duration) error {
	_ = s.tokenCache.BlacklistToken(ctx, tokenID, ttl)
	return nil
}

func (s *AuthService) InviteUser(ctx context.Context, inviterID uuid.UUID, orgSchema string, orgName string, req request.InviteUserRequest) (*response.UserResponse, error) {
	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return nil, err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)

	_, err = tenantUserRepo.FindByEmail(ctx, req.Email)
	if err == nil {
		return nil, domain.ErrAlreadyExists
	}

	// Generate readable temp password: 12 chars
	rawTemp := generateReadablePassword()
	hash, err := bcrypt.GenerateFromPassword([]byte(rawTemp), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}

	user := &domain.User{
		Name:               req.Name,
		Email:              req.Email,
		PasswordHash:       string(hash),
		Role:               domain.Role(req.Role),
		IsActive:           true,
		MustChangePassword: true, // force password change on first login
		InvitedBy:          &inviterID,
	}

	if err := tenantUserRepo.Create(ctx, user); err != nil {
		return nil, err
	}

	// Send invite email asynchronously — don't block or fail if it errors
	go func() {
		bgCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = s.notificationClient.SendInviteEmail(
			bgCtx,
			req.Email,
			req.Name,
			orgName,
			req.Role,
			rawTemp,
			s.appBaseURL+"/login",
		)
	}()

	res := toUserResponse(user)
	return &res, nil
}

func (s *AuthService) UpdateRole(ctx context.Context, userID uuid.UUID, orgSchema string, req request.UpdateRoleRequest) (*response.UserResponse, error) {
	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return nil, err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)

	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	user.Role = domain.Role(req.Role)
	if err := tenantUserRepo.Update(ctx, user); err != nil {
		return nil, err
	}
	res := toUserResponse(user)
	return &res, nil
}

func (s *AuthService) GetProfile(ctx context.Context, userID uuid.UUID, orgSchema string) (*response.UserResponse, error) {
	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return nil, err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	res := toUserResponse(user)
	return &res, nil
}

func (s *AuthService) UpdateProfile(ctx context.Context, userID uuid.UUID, orgSchema string, req request.UpdateProfileRequest) (*response.UserResponse, error) {
	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return nil, err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if req.Name != "" {
		user.Name = req.Name
	}
	if err := tenantUserRepo.Update(ctx, user); err != nil {
		return nil, err
	}
	res := toUserResponse(user)
	return &res, nil
}

func (s *AuthService) ChangePassword(ctx context.Context, userID uuid.UUID, orgSchema string, req request.ChangePasswordRequest) error {
	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return err
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.CurrentPassword)); err != nil {
		return domain.ErrInvalidCredentials
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	user.PasswordHash = string(hash)
	user.MustChangePassword = false // clear the flag after password change
	return tenantUserRepo.Update(ctx, user)
}

func (s *AuthService) ListUsers(ctx context.Context, orgSchema string, limit, offset int) ([]response.UserResponse, int64, error) {
	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return nil, 0, err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	users, total, err := tenantUserRepo.List(ctx, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	var res []response.UserResponse
	for _, u := range users {
		res = append(res, toUserResponse(&u))
	}
	return res, total, nil
}

func (s *AuthService) issueTokenPair(ctx context.Context, user *domain.User, org *domain.Org, tdb *gorm.DB) (*response.TokenPair, error) {
	accessToken, err := s.jwt.Sign(user.ID.String(), org.ID.String(), org.SchemaName, string(user.Role))
	if err != nil {
		return nil, err
	}

	rawRefresh := generateToken(32)
	refreshHash := hashToken(rawRefresh)
	refreshExpiry := time.Now().Add(7 * 24 * time.Hour)

	tenantTokenRepo := postgres.NewTokenRepository(tdb)
	if err := tenantTokenRepo.SaveRefreshToken(ctx, user.ID, refreshHash, refreshExpiry); err != nil {
		return nil, err
	}

	return &response.TokenPair{
		AccessToken:  accessToken,
		RefreshToken: rawRefresh,
		ExpiresAt:    refreshExpiry.Unix(),
	}, nil
}

func hashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}

func generateToken(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// generateReadablePassword generates a human-readable temp password
func generateReadablePassword() string {
	const chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
	b := make([]byte, 12)
	rand.Read(b)
	for i := range b {
		b[i] = chars[int(b[i])%len(chars)]
	}
	return string(b)
}

func toUserResponse(u *domain.User) response.UserResponse {
	return response.UserResponse{
		ID:                 u.ID.String(),
		Name:               u.Name,
		Email:              u.Email,
		Role:               string(u.Role),
		IsActive:           u.IsActive,
		MustChangePassword: u.MustChangePassword,
		LastLoginAt:        u.LastLoginAt,
		CreatedAt:          u.CreatedAt,
	}
}

func toOrgResponse(o *domain.Org) response.OrgResponse {
	return response.OrgResponse{
		ID:         o.ID.String(),
		Name:       o.Name,
		SchemaName: o.SchemaName,
		Email:      o.Email,
		IsActive:   o.IsActive,
		CreatedAt:  o.CreatedAt,
	}
}
EOF

log "Auth service updated"

# =============================================================================
# 6. UPDATE HANDLER — pass orgName to InviteUser
# =============================================================================
info "Updating auth handler..."

cat > services/auth-service/internal/handler/auth_handler.go << 'EOF'
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
	orgID, _ := uuid.Parse(c.GetString(middleware.ContextOrgID))
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

	tokens, err := h.svc.RefreshToken(c.Request.Context(), orgID, rawRefreshToken)
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
EOF

log "Handler updated"

# =============================================================================
# 7. ADD ContextOrgName TO AUTH MIDDLEWARE
# =============================================================================
info "Updating auth middleware..."

cat > services/auth-service/internal/handler/middleware/auth.go << 'EOF'
package middleware

import (
	"strings"

	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
)

const (
	ContextUserID    = "user_id"
	ContextUserName  = "user_name"
	ContextOrgID     = "org_id"
	ContextOrgName   = "org_name"
	ContextOrgSchema = "org_schema"
	ContextRole      = "role"
)

func Auth(jwtManager *sharedjwt.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := ExtractToken(c)
		if token == "" {
			response.Unauthorized(c, "missing token")
			c.Abort()
			return
		}
		claims, err := jwtManager.Verify(token)
		if err != nil {
			response.Unauthorized(c, "invalid or expired token")
			c.Abort()
			return
		}
		c.Set(ContextUserID, claims.UserID)
		c.Set(ContextOrgID, claims.OrgID)
		c.Set(ContextOrgSchema, claims.OrgSchema)
		c.Set(ContextRole, claims.Role)
		c.Next()
	}
}

func RequireRole(roles ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		role := c.GetString(ContextRole)
		for _, r := range roles {
			if r == role {
				c.Next()
				return
			}
		}
		response.Forbidden(c, "insufficient permissions")
		c.Abort()
	}
}

func ExtractToken(c *gin.Context) string {
	bearer := c.GetHeader("Authorization")
	if strings.HasPrefix(bearer, "Bearer ") {
		return strings.TrimPrefix(bearer, "Bearer ")
	}
	cookie, err := c.Cookie("access_token")
	if err == nil {
		return cookie
	}
	return ""
}
EOF

log "Auth middleware updated"

# =============================================================================
# 8. UPDATE TENANT MIDDLEWARE to set org name from DB
# =============================================================================
info "Updating tenant middleware..."

cat > services/auth-service/internal/handler/middleware/tenant.go << 'EOF'
package middleware

import (
	"context"

	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const ContextDB = "tenant_db"

func Tenant(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
	}
}

func ResolveTenant(orgRepo irepository.OrgRepository, tokenCache *cache.TokenCache) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body struct {
			Email string `json:"email"`
		}
		if err := c.ShouldBindJSON(&body); err != nil || body.Email == "" {
			response.BadRequest(c, "email is required")
			c.Abort()
			return
		}

		ctx := context.Background()

		org, err := orgRepo.FindByEmail(ctx, body.Email)
		if err != nil {
			response.Unauthorized(c, "organisation not found for this email")
			c.Abort()
			return
		}

		_ = tokenCache.CacheOrgSchema(ctx, org.ID.String(), org.SchemaName)

		c.Set(ContextOrgID,     org.ID.String())
		c.Set(ContextOrgSchema, org.SchemaName)
		c.Set(ContextOrgName,   org.Name)
		c.Set("login_email",    body.Email)
		c.Next()
	}
}
EOF

log "Tenant middleware updated"

# =============================================================================
# 9. UPDATE DI to wire notification client
# =============================================================================
info "Updating DI container..."

cat > services/auth-service/internal/di/wire.go << 'EOF'
package di

import (
	"fmt"

	"github.com/ecocomply/auth-service/internal/config"
	"github.com/ecocomply/auth-service/internal/repository/cache"
	irepository "github.com/ecocomply/auth-service/internal/repository/interface"
	"github.com/ecocomply/auth-service/internal/repository/postgres"
	"github.com/ecocomply/auth-service/internal/service"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	gredis "github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config     *config.Config
	DB         *gorm.DB
	Redis      *gredis.Client
	JWTManager *sharedjwt.Manager
	TokenCache *cache.TokenCache

	UserRepo  irepository.UserRepository
	OrgRepo   irepository.OrgRepository
	TokenRepo irepository.TokenRepository

	AuthService *service.AuthService
}

func NewContainer(cfg *config.Config) (*Container, error) {
	dbCfg := sharedpostgres.Config{
		Host:     cfg.DBHost,
		Port:     cfg.DBPort,
		User:     cfg.DBUser,
		Password: cfg.DBPassword,
		DBName:   cfg.DBName,
	}

	db, err := sharedpostgres.Connect(dbCfg)
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}

	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host:     cfg.RedisHost,
		Port:     cfg.RedisPort,
		Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}

	jwtManager        := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)
	tokenCache        := cache.NewTokenCache(rdb)
	notificationClient := service.NewNotificationClient(cfg.NotificationServiceURL)

	orgRepo   := postgres.NewOrgRepository(db)
	userRepo  := postgres.NewUserRepository(db)
	tokenRepo := postgres.NewTokenRepository(db)

	authSvc := service.NewAuthService(
		dbCfg, db,
		userRepo, orgRepo, tokenRepo,
		tokenCache, jwtManager,
		notificationClient,
		cfg.AppBaseURL,
	)

	return &Container{
		Config:      cfg,
		DB:          db,
		Redis:       rdb,
		JWTManager:  jwtManager,
		TokenCache:  tokenCache,
		UserRepo:    userRepo,
		OrgRepo:     orgRepo,
		TokenRepo:   tokenRepo,
		AuthService: authSvc,
	}, nil
}
EOF

log "DI container updated"

# =============================================================================
# 10. ADD must_change_password COLUMN TO EXISTING SCHEMAS
# =============================================================================
info "Adding must_change_password column to existing tenant schemas..."

docker compose exec postgres psql -U postgres -d ecocomply -c "
DO \$\$
DECLARE
    schema_name text;
BEGIN
    FOR schema_name IN
        SELECT s.schema_name
        FROM information_schema.schemata s
        WHERE s.schema_name LIKE 'org_%'
    LOOP
        EXECUTE format(
            'ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT FALSE',
            schema_name
        );
    END LOOP;
END
\$\$;
"

log "Database columns updated"

# =============================================================================
# 11. UPDATE PROVISION FUNCTION to include must_change_password
# =============================================================================
info "Updating provision_org_schema function..."

docker compose exec postgres psql -U postgres -d ecocomply -c "
CREATE OR REPLACE FUNCTION provision_org_schema(p_schema_name TEXT)
RETURNS VOID AS \$\$
DECLARE
    v_schema TEXT := quote_ident(p_schema_name);
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %s', v_schema);

    EXECUTE format(\$fmt\$
        DO \$inner\$ BEGIN
            CREATE TYPE %s.user_role AS ENUM (
                'org_admin', 'manager', 'supervisor', 'enumerator'
            );
        EXCEPTION WHEN duplicate_object THEN NULL;
        END \$inner\$;
    \$fmt\$, v_schema);

    EXECUTE format(\$fmt\$
        CREATE TABLE IF NOT EXISTS %s.users (
            id                  UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
            name                TEXT             NOT NULL,
            email               TEXT             NOT NULL UNIQUE,
            password_hash       TEXT             NOT NULL,
            role                %s.user_role     NOT NULL DEFAULT 'enumerator',
            is_active           BOOLEAN          NOT NULL DEFAULT TRUE,
            must_change_password BOOLEAN         NOT NULL DEFAULT FALSE,
            invited_by          UUID,
            last_login_at       TIMESTAMPTZ,
            created_at          TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
            updated_at          TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
            deleted_at          TIMESTAMPTZ,
            CONSTRAINT fk_invited_by FOREIGN KEY (invited_by)
                REFERENCES %s.users (id) ON DELETE SET NULL
        )
    \$fmt\$, v_schema, v_schema, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_email      ON %s.users (email)',      v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_role       ON %s.users (role)',       v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON %s.users (deleted_at)', v_schema);

    EXECUTE format(\$fmt\$
        CREATE TABLE IF NOT EXISTS %s.password_reset_tokens (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID        NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash  TEXT        NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            used_at     TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    \$fmt\$, v_schema, v_schema);

    EXECUTE format(\$fmt\$
        CREATE TABLE IF NOT EXISTS %s.refresh_tokens (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID        NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash  TEXT        NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            revoked_at  TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    \$fmt\$, v_schema, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_rt_user_id    ON %s.refresh_tokens (user_id)',        v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_rt_expires_at ON %s.refresh_tokens (expires_at)',     v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_prt_user_id   ON %s.password_reset_tokens (user_id)', v_schema);

    EXECUTE format(\$fmt\$
        CREATE OR REPLACE FUNCTION %s.trigger_set_updated_at()
        RETURNS TRIGGER AS \$fn\$
        BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
        \$fn\$ LANGUAGE plpgsql
    \$fmt\$, v_schema);

    EXECUTE format(\$fmt\$
        CREATE TRIGGER set_users_updated_at
            BEFORE UPDATE ON %s.users
            FOR EACH ROW
            EXECUTE FUNCTION %s.trigger_set_updated_at()
    \$fmt\$, v_schema, v_schema);
END;
\$\$ LANGUAGE plpgsql;
"

log "provision_org_schema function updated"

# =============================================================================
# 12. REBUILD AUTH SERVICE
# =============================================================================
info "Rebuilding auth-service..."

docker compose up --build -d auth-service

# =============================================================================
# 13. UPDATE FRONTEND — redirect to change-password if must_change_password
# =============================================================================
info "Updating frontend login page..."

cat > ~/ecocomplyng-ui/src/app/\(auth\)/login/page.tsx << 'TSXEOF'
"use client";
import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { motion } from "framer-motion";
import { api } from "@/lib/api";
import { useAuthStore } from "@/stores/auth.store";
import { useToast } from "@/components/ui/Toast";

const schema = z.object({
  email: z.string().email("Enter a valid email"),
  password: z.string().min(1, "Password is required"),
});
type FormData = z.infer<typeof schema>;

export default function LoginPage() {
  const router  = useRouter();
  const setAuth = useAuthStore((s) => s.setAuth);
  const { success, error } = useToast();
  const [loading, setLoading] = useState(false);

  const { register, handleSubmit, formState: { errors } } = useForm<FormData>({
    resolver: zodResolver(schema),
  });

  const onSubmit = async (data: FormData) => {
    setLoading(true);
    try {
      const res = await api.post("/api/v1/auth/login", data);
      const { user, org } = res.data.data;
      setAuth(user, org);
      success("Welcome back!");

      // If invited user — force password change
      if (user.must_change_password) {
        router.push("/dashboard/profile/change-password");
      } else {
        router.push("/dashboard");
      }
    } catch (err: any) {
      error(err.response?.data?.error ?? "Login failed. Check your credentials.");
    } finally {
      setLoading(false);
    }
  };

  const inputStyle: React.CSSProperties = {
    width: "100%",
    padding: "0.75rem 1rem",
    borderRadius: "0.5rem",
    border: "1px solid rgba(255,255,255,0.3)",
    background: "rgba(255,255,255,0.15)",
    color: "white",
    fontSize: "0.9375rem",
    outline: "none",
  };

  return (
    <div style={{ display: "flex", minHeight: "100vh", width: "100%" }}>
      <div style={{
        flex: 1, position: "relative", overflow: "hidden",
        display: "flex", flexDirection: "column", justifyContent: "flex-end", padding: "3rem",
      }}>
        <div style={{
          position: "absolute", inset: 0,
          backgroundImage: `url("https://images.unsplash.com/photo-1441974231531-c6227db76b6e?w=1920&q=90")`,
          backgroundSize: "cover", backgroundPosition: "center",
          filter: "blur(2px) brightness(0.72)", transform: "scale(1.04)",
        }} />
        <div style={{
          position: "absolute", inset: 0,
          background: "linear-gradient(to bottom, rgba(0,20,5,0.15) 0%, rgba(0,40,10,0.82) 100%)",
        }} />
        <div style={{ position: "absolute", top: "2rem", left: "2.5rem", display: "flex", alignItems: "center", gap: "0.75rem", zIndex: 1 }}>
          <div style={{ width: 44, height: 44, borderRadius: "0.75rem", backgroundColor: "#16a34a", display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "0 4px 20px rgba(22,163,74,0.5)" }}>
            <svg width="22" height="22" fill="none" stroke="white" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 3v4M3 5h4M6 17v4m-2-2h4m5-16l2.286 6.857L21 12l-5.714 2.143L13 21l-2.286-6.857L5 12l5.714-2.143L13 3z" />
            </svg>
          </div>
          <span style={{ color: "white", fontWeight: 700, fontSize: "1.125rem" }}>EcoComply NG</span>
        </div>
        <div style={{ position: "relative", zIndex: 1 }}>
          <div style={{ display: "inline-flex", alignItems: "center", gap: "0.5rem", background: "rgba(22,163,74,0.25)", border: "1px solid rgba(74,222,128,0.4)", borderRadius: "2rem", padding: "0.375rem 1rem", marginBottom: "1.25rem" }}>
            <span style={{ width: 8, height: 8, borderRadius: "50%", background: "#4ade80", display: "inline-block" }} />
            <span style={{ color: "#86efac", fontSize: "0.8125rem", fontWeight: 500 }}>NESREA · FEPA · EIA Compliance</span>
          </div>
          <h2 style={{ color: "white", fontSize: "2.25rem", fontWeight: 700, lineHeight: 1.2, marginBottom: "1rem", maxWidth: 480 }}>
            Digitising Environmental Compliance in Nigeria
          </h2>
          <p style={{ color: "rgba(255,255,255,0.75)", fontSize: "1rem", lineHeight: 1.7, maxWidth: 440, marginBottom: "2rem" }}>
            Streamline EIA monitoring, field inspections, and compliance reporting for infrastructure projects, contractors, and government officers.
          </p>
          <div style={{ display: "flex", gap: "2rem" }}>
            {[{ value: "500+", label: "Inspections logged" }, { value: "3", label: "Checklist frameworks" }, { value: "100%", label: "Audit-ready reports" }].map((stat) => (
              <div key={stat.label}>
                <p style={{ color: "white", fontSize: "1.5rem", fontWeight: 700, lineHeight: 1 }}>{stat.value}</p>
                <p style={{ color: "rgba(255,255,255,0.6)", fontSize: "0.8125rem", marginTop: "0.25rem" }}>{stat.label}</p>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div style={{ width: "100%", maxWidth: 520, background: "rgba(8, 22, 8, 0.88)", backdropFilter: "blur(24px)", WebkitBackdropFilter: "blur(24px)", display: "flex", flexDirection: "column", justifyContent: "center", padding: "3rem 3.5rem", borderLeft: "1px solid rgba(255,255,255,0.08)" }}>
        <motion.div initial={{ opacity: 0, x: 20 }} animate={{ opacity: 1, x: 0 }} transition={{ duration: 0.45, ease: "easeOut" }}>
          <h2 style={{ color: "white", fontSize: "1.75rem", fontWeight: 700, marginBottom: "0.375rem" }}>Sign in</h2>
          <p style={{ color: "rgba(255,255,255,0.5)", fontSize: "0.9375rem", marginBottom: "2.25rem" }}>Access your compliance dashboard</p>

          <form onSubmit={handleSubmit(onSubmit)} style={{ display: "flex", flexDirection: "column", gap: "1.25rem" }}>
            <div>
              <label style={{ color: "rgba(255,255,255,0.8)", fontSize: "0.875rem", fontWeight: 500, display: "block", marginBottom: "0.5rem" }}>Email address</label>
              <input {...register("email")} type="email" placeholder="you@example.com" autoComplete="email" style={inputStyle}
                onFocus={(e) => { e.target.style.borderColor = "#4ade80"; e.target.style.boxShadow = "0 0 0 3px rgba(74,222,128,0.2)"; }}
                onBlur={(e)  => { e.target.style.borderColor = "rgba(255,255,255,0.3)"; e.target.style.boxShadow = "none"; }} />
              {errors.email && <p style={{ color: "#fca5a5", fontSize: "0.8125rem", marginTop: "0.375rem" }}>{errors.email.message}</p>}
            </div>
            <div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "0.5rem" }}>
                <label style={{ color: "rgba(255,255,255,0.8)", fontSize: "0.875rem", fontWeight: 500 }}>Password</label>
                <Link href="/forgot-password" style={{ color: "#86efac", fontSize: "0.8125rem", textDecoration: "none" }}>Forgot password?</Link>
              </div>
              <input {...register("password")} type="password" placeholder="••••••••" autoComplete="current-password" style={inputStyle}
                onFocus={(e) => { e.target.style.borderColor = "#4ade80"; e.target.style.boxShadow = "0 0 0 3px rgba(74,222,128,0.2)"; }}
                onBlur={(e)  => { e.target.style.borderColor = "rgba(255,255,255,0.3)"; e.target.style.boxShadow = "none"; }} />
              {errors.password && <p style={{ color: "#fca5a5", fontSize: "0.8125rem", marginTop: "0.375rem" }}>{errors.password.message}</p>}
            </div>
            <button type="submit" disabled={loading} style={{ width: "100%", padding: "0.875rem 1rem", borderRadius: "0.5rem", background: loading ? "rgba(22,163,74,0.5)" : "linear-gradient(135deg, #16a34a 0%, #15803d 100%)", color: "white", fontWeight: 600, fontSize: "1rem", border: "none", cursor: loading ? "not-allowed" : "pointer", display: "flex", alignItems: "center", justifyContent: "center", gap: "0.5rem", marginTop: "0.5rem", boxShadow: "0 4px 20px rgba(22,163,74,0.3)" }}>
              {loading && <svg style={{ animation: "spin 1s linear infinite", width: 18, height: 18 }} fill="none" viewBox="0 0 24 24"><circle style={{ opacity: 0.25 }} cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path style={{ opacity: 0.75 }} fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" /></svg>}
              {loading ? "Signing in..." : "Sign in"}
            </button>
          </form>

          <p style={{ color: "rgba(255,255,255,0.5)", fontSize: "0.9375rem", textAlign: "center", marginTop: "2rem" }}>
            New organisation?{" "}
            <Link href="/register" style={{ color: "#86efac", fontWeight: 600, textDecoration: "none" }}>Register here</Link>
          </p>

          <div style={{ marginTop: "2.5rem", paddingTop: "1.5rem", borderTop: "1px solid rgba(255,255,255,0.08)", display: "flex", justifyContent: "center", gap: "1.5rem" }}>
            {["GBV Compliant", "HSE Monitored", "EIA Tracked"].map((badge) => (
              <div key={badge} style={{ display: "flex", alignItems: "center", gap: "0.375rem" }}>
                <svg width="14" height="14" fill="none" viewBox="0 0 24 24" stroke="#4ade80" strokeWidth="2.5"><path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" /></svg>
                <span style={{ color: "rgba(255,255,255,0.45)", fontSize: "0.75rem" }}>{badge}</span>
              </div>
            ))}
          </div>
        </motion.div>
      </div>
    </div>
  );
}
TSXEOF

log "Frontend login updated"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Invite flow implementation complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  What was done:"
echo "  1. Added must_change_password to User domain + DB"
echo "  2. Invite now generates a readable temp password"
echo "  3. Invite email sent via notification-service (async)"
echo "  4. Login redirects to change-password if must_change_password = true"
echo "  5. ChangePassword clears must_change_password flag"
echo "  6. Mobile clients get tokens in body via X-Client-Type: mobile header"
echo "  7. Web clients get httpOnly cookies only"
echo ""
echo "  Invited user flow:"
echo "  1. Admin invites user → email sent with temp password"
echo "  2. User logs in with temp password"
echo "  3. Frontend detects must_change_password = true"
echo "  4. Redirects to /dashboard/profile/change-password"
echo "  5. User sets new password → normal dashboard access"
echo ""
