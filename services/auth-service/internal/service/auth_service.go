package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
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

func (s *AuthService) RefreshToken(ctx context.Context, rawToken string) (*response.TokenPair, error) {
	tokenHash := hashToken(rawToken)

	orgIDStr, schema, err := s.tokenCache.GetRefreshTokenContext(ctx, tokenHash)
	if err != nil {
		return nil, domain.ErrTokenInvalid
	}
	orgID, err := uuid.Parse(orgIDStr)
	if err != nil {
		return nil, domain.ErrTokenInvalid
	}

	org, err := s.orgRepo.FindByID(ctx, orgID)
	if err != nil {
		return nil, err
	}

	tdb, err := s.tenantDB(schema)
	if err != nil {
		return nil, err
	}

	tenantTokenRepo := postgres.NewTokenRepository(tdb)
	userID, _, err := tenantTokenRepo.FindRefreshToken(ctx, tokenHash)
	if err != nil {
		return nil, domain.ErrTokenInvalid
	}
	_ = tenantTokenRepo.RevokeRefreshToken(ctx, tokenHash)
	_ = s.tokenCache.DeleteRefreshTokenContext(ctx, tokenHash)

	tenantUserRepo := postgres.NewUserRepository(tdb)
	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	return s.issueTokenPair(ctx, user, org, tdb)
}

func (s *AuthService) Logout(ctx context.Context, tokenID string, rawRefreshToken string, ttl time.Duration) error {
	_ = s.tokenCache.BlacklistToken(ctx, tokenID, ttl)
	if rawRefreshToken != "" {
		_ = s.tokenCache.DeleteRefreshTokenContext(ctx, hashToken(rawRefreshToken))
	}
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

	if orgName == "" {
		if org, lookupErr := s.orgRepo.FindBySchemaName(ctx, orgSchema); lookupErr == nil {
			orgName = org.Name
		}
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

func (s *AuthService) ForgotPassword(ctx context.Context, orgSchema string, req request.ForgotPasswordRequest) error {
	if orgSchema == "" {
		return domain.ErrInvalidInput
	}

	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	tenantTokenRepo := postgres.NewTokenRepository(tdb)

	user, err := tenantUserRepo.FindByEmail(ctx, req.Email)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			return nil
		}
		return err
	}

	rawReset := generateToken(24)
	resetHash := hashToken(rawReset)
	expiresAt := time.Now().Add(1 * time.Hour)
	if err := tenantTokenRepo.SaveResetToken(ctx, user.ID, resetHash, expiresAt); err != nil {
		return err
	}

	resetURL := fmt.Sprintf("%s/reset-password?token=%s.%s", s.appBaseURL, orgSchema, rawReset)
	go func(name, email, url string) {
		bgCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = s.notificationClient.SendPasswordResetEmail(bgCtx, email, name, url)
	}(user.Name, user.Email, resetURL)

	return nil
}

func (s *AuthService) ResetPassword(ctx context.Context, req request.ResetPasswordRequest) error {
	parts := strings.SplitN(req.Token, ".", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return domain.ErrTokenInvalid
	}
	orgSchema := parts[0]
	rawToken := parts[1]

	tdb, err := s.tenantDB(orgSchema)
	if err != nil {
		return err
	}
	tenantUserRepo := postgres.NewUserRepository(tdb)
	tenantTokenRepo := postgres.NewTokenRepository(tdb)

	userID, expiresAt, used, err := tenantTokenRepo.FindResetToken(ctx, hashToken(rawToken))
	if err != nil {
		return domain.ErrTokenInvalid
	}
	if used || time.Now().After(expiresAt) {
		return domain.ErrTokenExpired
	}

	user, err := tenantUserRepo.FindByID(ctx, userID)
	if err != nil {
		return err
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	user.PasswordHash = string(hash)
	user.MustChangePassword = false
	if err := tenantUserRepo.Update(ctx, user); err != nil {
		return err
	}
	if err := tenantTokenRepo.MarkResetTokenUsed(ctx, hashToken(rawToken)); err != nil {
		return err
	}
	return tenantTokenRepo.RevokeAllUserTokens(ctx, userID)
}

func (s *AuthService) issueTokenPair(ctx context.Context, user *domain.User, org *domain.Org, tdb *gorm.DB) (*response.TokenPair, error) {
	accessToken, err := s.jwt.Sign(user.ID.String(), user.Name, org.ID.String(), org.SchemaName, string(user.Role))
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
	_ = s.tokenCache.CacheRefreshTokenContext(ctx, refreshHash, org.ID.String(), org.SchemaName, 7*24*time.Hour)

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
