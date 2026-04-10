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
	db                 *gorm.DB
	userRepo           irepository.UserRepository
	orgRepo            irepository.OrgRepository
	tokenRepo          irepository.TokenRepository
	tokenCache         *cache.TokenCache
	jwt                *sharedjwt.Manager
	notificationClient *NotificationClient
	appBaseURL         string
}

func NewAuthService(
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

	if err := withTenantTx(ctx, s.db, schemaName, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		return tenantUserRepo.Create(tenantCtx, admin)
	}); err != nil {
		return nil, fmt.Errorf("tenant db transaction failed: %w", err)
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

	var result *response.LoginResponse
	err = withTenantTx(ctx, s.db, org.SchemaName, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)

		user, err := tenantUserRepo.FindByEmail(tenantCtx, req.Email)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				return domain.ErrInvalidCredentials
			}
			return err
		}

		if !user.IsActive {
			return domain.ErrAccountInactive
		}

		if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
			return domain.ErrInvalidCredentials
		}

		tokens, err := s.issueTokenPair(tenantCtx, user, org, tdb)
		if err != nil {
			return err
		}

		now := time.Now()
		user.LastLoginAt = &now
		_ = tenantUserRepo.Update(tenantCtx, user)

		result = &response.LoginResponse{
			Tokens: *tokens,
			User:   toUserResponse(user),
			Org:    toOrgResponse(org),
		}

		return nil
	})
	if err != nil {
		return nil, err
	}

	return result, nil
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

	var tokens *response.TokenPair
	err = withTenantTx(ctx, s.db, schema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantTokenRepo := postgres.NewTokenRepository(tdb)
		userID, _, err := tenantTokenRepo.FindRefreshToken(tenantCtx, tokenHash)
		if err != nil {
			return domain.ErrTokenInvalid
		}
		_ = tenantTokenRepo.RevokeRefreshToken(tenantCtx, tokenHash)
		_ = s.tokenCache.DeleteRefreshTokenContext(tenantCtx, tokenHash)

		tenantUserRepo := postgres.NewUserRepository(tdb)
		user, err := tenantUserRepo.FindByID(tenantCtx, userID)
		if err != nil {
			return err
		}

		tokens, err = s.issueTokenPair(tenantCtx, user, org, tdb)
		return err
	})
	if err != nil {
		return nil, err
	}

	return tokens, nil
}

func (s *AuthService) Logout(ctx context.Context, tokenID string, rawRefreshToken string, ttl time.Duration) error {
	_ = s.tokenCache.BlacklistToken(ctx, tokenID, ttl)
	if rawRefreshToken != "" {
		_ = s.tokenCache.DeleteRefreshTokenContext(ctx, hashToken(rawRefreshToken))
	}
	return nil
}

func (s *AuthService) InviteUser(ctx context.Context, inviterID uuid.UUID, orgSchema string, orgName string, req request.InviteUserRequest) (*response.UserResponse, error) {
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

	if err := withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)

		_, err := tenantUserRepo.FindByEmail(tenantCtx, req.Email)
		if err == nil {
			return domain.ErrAlreadyExists
		}
		if err != nil && !errors.Is(err, domain.ErrNotFound) {
			return err
		}

		return tenantUserRepo.Create(tenantCtx, user)
	}); err != nil {
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
	var res response.UserResponse
	err := withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)

		user, err := tenantUserRepo.FindByID(tenantCtx, userID)
		if err != nil {
			return err
		}
		user.Role = domain.Role(req.Role)
		if err := tenantUserRepo.Update(tenantCtx, user); err != nil {
			return err
		}
		res = toUserResponse(user)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}

func (s *AuthService) GetProfile(ctx context.Context, userID uuid.UUID, orgSchema string) (*response.UserResponse, error) {
	var res response.UserResponse
	err := withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		user, err := tenantUserRepo.FindByID(tenantCtx, userID)
		if err != nil {
			return err
		}
		res = toUserResponse(user)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}

func (s *AuthService) UpdateProfile(ctx context.Context, userID uuid.UUID, orgSchema string, req request.UpdateProfileRequest) (*response.UserResponse, error) {
	var res response.UserResponse
	err := withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		user, err := tenantUserRepo.FindByID(tenantCtx, userID)
		if err != nil {
			return err
		}
		if req.Name != "" {
			user.Name = req.Name
		}
		if err := tenantUserRepo.Update(tenantCtx, user); err != nil {
			return err
		}
		res = toUserResponse(user)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}

func (s *AuthService) ChangePassword(ctx context.Context, userID uuid.UUID, orgSchema string, req request.ChangePasswordRequest) error {
	return withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		user, err := tenantUserRepo.FindByID(tenantCtx, userID)
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
		return tenantUserRepo.Update(tenantCtx, user)
	})
}

func (s *AuthService) ListUsers(ctx context.Context, orgSchema string, limit, offset int) ([]response.UserResponse, int64, error) {
	var (
		users []domain.User
		total int64
	)
	err := withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		var err error
		users, total, err = tenantUserRepo.List(tenantCtx, limit, offset)
		return err
	})
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

	var (
		user     *domain.User
		rawReset string
	)
	err := withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		tenantTokenRepo := postgres.NewTokenRepository(tdb)

		var err error
		user, err = tenantUserRepo.FindByEmail(tenantCtx, req.Email)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				return nil
			}
			return err
		}

		rawReset = generateToken(24)
		resetHash := hashToken(rawReset)
		expiresAt := time.Now().Add(1 * time.Hour)
		return tenantTokenRepo.SaveResetToken(tenantCtx, user.ID, resetHash, expiresAt)
	})
	if err != nil {
		return err
	}
	if user == nil {
		return nil
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

	return withTenantTx(ctx, s.db, orgSchema, func(tenantCtx context.Context, tdb *gorm.DB) error {
		tenantUserRepo := postgres.NewUserRepository(tdb)
		tenantTokenRepo := postgres.NewTokenRepository(tdb)

		userID, expiresAt, used, err := tenantTokenRepo.FindResetToken(tenantCtx, hashToken(rawToken))
		if err != nil {
			return domain.ErrTokenInvalid
		}
		if used || time.Now().After(expiresAt) {
			return domain.ErrTokenExpired
		}

		user, err := tenantUserRepo.FindByID(tenantCtx, userID)
		if err != nil {
			return err
		}

		hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
		if err != nil {
			return err
		}
		user.PasswordHash = string(hash)
		user.MustChangePassword = false
		if err := tenantUserRepo.Update(tenantCtx, user); err != nil {
			return err
		}
		if err := tenantTokenRepo.MarkResetTokenUsed(tenantCtx, hashToken(rawToken)); err != nil {
			return err
		}
		return tenantTokenRepo.RevokeAllUserTokens(tenantCtx, userID)
	})
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

func withTenantTx(ctx context.Context, db *gorm.DB, schema string, fn func(context.Context, *gorm.DB) error) error {
	tx, err := sharedpostgres.BeginTenantTx(ctx, db, schema)
	if err != nil {
		return err
	}

	tenantCtx := sharedpostgres.ContextWithDB(ctx, tx)
	if err := fn(tenantCtx, tx); err != nil {
		_ = tx.Rollback().Error
		return err
	}

	if err := tx.Commit().Error; err != nil {
		_ = tx.Rollback().Error
		return err
	}

	return nil
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
