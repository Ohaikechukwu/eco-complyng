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
