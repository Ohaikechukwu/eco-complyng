package domain

import (
	"github.com/google/uuid"
	"time"
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
