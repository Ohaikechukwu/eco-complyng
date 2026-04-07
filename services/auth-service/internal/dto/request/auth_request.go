package request

// RegisterOrgRequest is used when a new organisation signs up.
// This creates the org row + provisions the isolated schema + seeds the org_admin user.
type RegisterOrgRequest struct {
	OrgName  string `json:"org_name"  binding:"required,min=2,max=100"`
	Email    string `json:"email"     binding:"required,email"`
	Password string `json:"password"  binding:"required,min=8"`
	Name     string `json:"name"      binding:"required,min=2,max=100"`
}

// LoginRequest is used for both org admin and member login.
type LoginRequest struct {
	Email        string `json:"email"         binding:"required,email"`
	Password     string `json:"password"      binding:"required"`
	OrgSchema    string `json:"org_schema"`
	Organization string `json:"organization"`
}

// RefreshTokenRequest is sent when the client needs a new access token.
type RefreshTokenRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

// ForgotPasswordRequest initiates a password reset email.
type ForgotPasswordRequest struct {
	Email        string `json:"email"        binding:"required,email"`
	OrgSchema    string `json:"org_schema"`
	Organization string `json:"organization"`
}

// ResetPasswordRequest completes the password reset flow.
type ResetPasswordRequest struct {
	Token       string `json:"token"        binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=8"`
}

// InviteUserRequest is used by org_admin to provision a new user.
type InviteUserRequest struct {
	Name  string `json:"name"  binding:"required,min=2,max=100"`
	Email string `json:"email" binding:"required,email"`
	Role  string `json:"role"  binding:"required,oneof=manager supervisor enumerator"`
}

// UpdateRoleRequest is used by org_admin to change a user's role.
type UpdateRoleRequest struct {
	Role string `json:"role" binding:"required,oneof=manager supervisor enumerator"`
}

// UpdateProfileRequest is used by any user to update their own profile.
type UpdateProfileRequest struct {
	Name string `json:"name" binding:"omitempty,min=2,max=100"`
}

// ChangePasswordRequest is used by a logged-in user to change their password.
type ChangePasswordRequest struct {
	CurrentPassword string `json:"current_password" binding:"required"`
	NewPassword     string `json:"new_password"     binding:"required,min=8"`
}
