package domain

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Org struct {
	ID         uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Name       string    `gorm:"not null"`
	SchemaName string    `gorm:"uniqueIndex;not null"`
	Email      string    `gorm:"uniqueIndex;not null"`
	IsActive   bool      `gorm:"not null;default:true"`
	CreatedAt  time.Time
	UpdatedAt  time.Time
	DeletedAt  *time.Time `gorm:"index"`
}

func (Org) TableName() string { return "orgs" }

var nonAlphanumeric = regexp.MustCompile(`[^a-z0-9]+`)

// SchemaNameFrom converts an org name to a safe Postgres schema name.
// e.g. "Acme Corp Nigeria" → "org_acme_corp_nigeria"
func SchemaNameFrom(orgName string) string {
	lower := strings.ToLower(orgName)
	safe := nonAlphanumeric.ReplaceAllString(lower, "_")
	safe = strings.Trim(safe, "_")
	return fmt.Sprintf("org_%s", safe)
}
