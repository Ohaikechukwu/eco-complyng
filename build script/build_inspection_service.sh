#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EcoComply NG — inspection-service complete build script
# Run from inside ~/ecocomply-ng:
#   chmod +x build_inspection_service.sh && ./build_inspection_service.sh
# =============================================================================

BASE="services/inspection-service"
MODULE="github.com/ecocomply/inspection-service"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# =============================================================================
# 1. MIGRATIONS
# =============================================================================
info "Writing migrations..."

cat > "${BASE}/migrations/tenant/000001_create_inspections.up.sql" << 'EOF'
-- =============================================================================
-- Migration: 000001_create_inspections (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Inspection status enum
DO $$ BEGIN
    CREATE TYPE inspection_status AS ENUM (
        'draft',
        'in_progress',
        'submitted',
        'under_review',
        'pending_actions',
        'completed',
        'finalized'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Action status enum
DO $$ BEGIN
    CREATE TYPE action_status AS ENUM (
        'pending',
        'in_progress',
        'resolved',
        'overdue'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Checklist template (org-scoped; system templates cloned from public schema)
CREATE TABLE IF NOT EXISTS checklist_templates (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    description TEXT,
    is_system   BOOLEAN     NOT NULL DEFAULT FALSE,
    cloned_from UUID,                               -- references public.checklist_templates.id
    created_by  UUID        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ct_deleted_at ON checklist_templates (deleted_at);

-- Checklist template items
CREATE TABLE IF NOT EXISTS checklist_template_items (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id UUID        NOT NULL REFERENCES checklist_templates (id) ON DELETE CASCADE,
    description TEXT        NOT NULL,
    sort_order  INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cti_template_id ON checklist_template_items (template_id);

-- Inspections
CREATE TABLE IF NOT EXISTS inspections (
    id               UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
    project_name     TEXT               NOT NULL,
    location_name    TEXT,
    latitude         DOUBLE PRECISION,
    longitude        DOUBLE PRECISION,
    date             TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    inspector_name   TEXT               NOT NULL,   -- snapshot at creation
    inspector_role   TEXT               NOT NULL,   -- snapshot at creation
    assigned_user_id UUID               NOT NULL,
    checklist_id     UUID               REFERENCES checklist_templates (id) ON DELETE SET NULL,
    status           inspection_status  NOT NULL DEFAULT 'draft',
    notes            TEXT,
    created_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    deleted_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_inspections_status         ON inspections (status);
CREATE INDEX IF NOT EXISTS idx_inspections_assigned_user  ON inspections (assigned_user_id);
CREATE INDEX IF NOT EXISTS idx_inspections_date           ON inspections (date DESC);
CREATE INDEX IF NOT EXISTS idx_inspections_deleted_at     ON inspections (deleted_at);

-- Checklist items per inspection (copied from template at inspection creation)
CREATE TABLE IF NOT EXISTS checklist_items (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id UUID        NOT NULL REFERENCES inspections (id) ON DELETE CASCADE,
    template_item_id UUID,                          -- reference back to template item
    description   TEXT        NOT NULL,
    response      BOOLEAN,                          -- NULL=unanswered, TRUE=yes, FALSE=no
    comment       TEXT,
    sort_order    INT         NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ci_inspection_id ON checklist_items (inspection_id);

-- Agreed actions
CREATE TABLE IF NOT EXISTS agreed_actions (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id UUID          NOT NULL REFERENCES inspections (id) ON DELETE CASCADE,
    description   TEXT          NOT NULL,
    assignee_id   UUID          NOT NULL,
    due_date      TIMESTAMPTZ   NOT NULL,
    status        action_status NOT NULL DEFAULT 'pending',
    evidence_url  TEXT,
    resolved_at   TIMESTAMPTZ,
    created_by    UUID          NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_aa_inspection_id ON agreed_actions (inspection_id);
CREATE INDEX IF NOT EXISTS idx_aa_assignee_id   ON agreed_actions (assignee_id);
CREATE INDEX IF NOT EXISTS idx_aa_due_date      ON agreed_actions (due_date);
CREATE INDEX IF NOT EXISTS idx_aa_status        ON agreed_actions (status);

-- Comments / review thread
CREATE TABLE IF NOT EXISTS inspection_comments (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id UUID        NOT NULL REFERENCES inspections (id) ON DELETE CASCADE,
    author_id     UUID        NOT NULL,
    body          TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ic_inspection_id ON inspection_comments (inspection_id);

-- updated_at trigger
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_inspections_updated_at
    BEFORE UPDATE ON inspections
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_checklist_items_updated_at
    BEFORE UPDATE ON checklist_items
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_agreed_actions_updated_at
    BEFORE UPDATE ON agreed_actions
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
EOF

cat > "${BASE}/migrations/tenant/000001_create_inspections.down.sql" << 'EOF'
DROP TRIGGER IF EXISTS set_agreed_actions_updated_at   ON agreed_actions;
DROP TRIGGER IF EXISTS set_checklist_items_updated_at  ON checklist_items;
DROP TRIGGER IF EXISTS set_inspections_updated_at      ON inspections;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE IF EXISTS inspection_comments;
DROP TABLE IF EXISTS agreed_actions;
DROP TABLE IF EXISTS checklist_items;
DROP TABLE IF EXISTS inspections;
DROP TABLE IF EXISTS checklist_template_items;
DROP TABLE IF EXISTS checklist_templates;
DROP TYPE  IF EXISTS action_status;
DROP TYPE  IF EXISTS inspection_status;
EOF

log "Migrations done"

# =============================================================================
# 2. DOMAIN
# =============================================================================
info "Writing domain layer..."

cat > "${BASE}/internal/domain/inspection.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type InspectionStatus string

const (
	StatusDraft          InspectionStatus = "draft"
	StatusInProgress     InspectionStatus = "in_progress"
	StatusSubmitted      InspectionStatus = "submitted"
	StatusUnderReview    InspectionStatus = "under_review"
	StatusPendingActions InspectionStatus = "pending_actions"
	StatusCompleted      InspectionStatus = "completed"
	StatusFinalized      InspectionStatus = "finalized"
)

// ValidTransitions defines allowed status moves.
var ValidTransitions = map[InspectionStatus][]InspectionStatus{
	StatusDraft:          {StatusInProgress},
	StatusInProgress:     {StatusSubmitted},
	StatusSubmitted:      {StatusUnderReview},
	StatusUnderReview:    {StatusPendingActions, StatusCompleted},
	StatusPendingActions: {StatusUnderReview, StatusCompleted},
	StatusCompleted:      {StatusFinalized},
	StatusFinalized:      {},
}

func (s InspectionStatus) CanTransitionTo(next InspectionStatus) bool {
	for _, allowed := range ValidTransitions[s] {
		if allowed == next {
			return true
		}
	}
	return false
}

type Inspection struct {
	ID             uuid.UUID        `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	ProjectName    string           `gorm:"not null"`
	LocationName   string
	Latitude       *float64
	Longitude      *float64
	Date           time.Time        `gorm:"not null"`
	InspectorName  string           `gorm:"not null"`
	InspectorRole  string           `gorm:"not null"`
	AssignedUserID uuid.UUID        `gorm:"type:uuid;not null"`
	ChecklistID    *uuid.UUID       `gorm:"type:uuid"`
	Status         InspectionStatus `gorm:"type:inspection_status;not null;default:draft"`
	Notes          string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	DeletedAt      *time.Time `gorm:"index"`

	// Associations (loaded on demand)
	ChecklistItems []ChecklistItem   `gorm:"foreignKey:InspectionID"`
	AgreedActions  []AgreedAction    `gorm:"foreignKey:InspectionID"`
	Comments       []InspectionComment `gorm:"foreignKey:InspectionID"`
}

func (Inspection) TableName() string { return "inspections" }
EOF

cat > "${BASE}/internal/domain/checklist.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type ChecklistTemplate struct {
	ID          uuid.UUID               `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	Name        string                  `gorm:"not null"`
	Description string
	IsSystem    bool                    `gorm:"not null;default:false"`
	ClonedFrom  *uuid.UUID              `gorm:"type:uuid"`
	CreatedBy   uuid.UUID               `gorm:"type:uuid;not null"`
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   *time.Time              `gorm:"index"`
	Items       []ChecklistTemplateItem `gorm:"foreignKey:TemplateID"`
}

func (ChecklistTemplate) TableName() string { return "checklist_templates" }

type ChecklistTemplateItem struct {
	ID          uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	TemplateID  uuid.UUID `gorm:"type:uuid;not null"`
	Description string    `gorm:"not null"`
	SortOrder   int
	CreatedAt   time.Time
}

func (ChecklistTemplateItem) TableName() string { return "checklist_template_items" }

type ChecklistItem struct {
	ID             uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID   uuid.UUID  `gorm:"type:uuid;not null"`
	TemplateItemID *uuid.UUID `gorm:"type:uuid"`
	Description    string     `gorm:"not null"`
	Response       *bool
	Comment        string
	SortOrder      int
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

func (ChecklistItem) TableName() string { return "checklist_items" }
EOF

cat > "${BASE}/internal/domain/action.go" << 'EOF'
package domain

import (
	"time"

	"github.com/google/uuid"
)

type ActionStatus string

const (
	ActionPending    ActionStatus = "pending"
	ActionInProgress ActionStatus = "in_progress"
	ActionResolved   ActionStatus = "resolved"
	ActionOverdue    ActionStatus = "overdue"
)

type AgreedAction struct {
	ID           uuid.UUID    `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID    `gorm:"type:uuid;not null"`
	Description  string       `gorm:"not null"`
	AssigneeID   uuid.UUID    `gorm:"type:uuid;not null"`
	DueDate      time.Time    `gorm:"not null"`
	Status       ActionStatus `gorm:"type:action_status;not null;default:pending"`
	EvidenceURL  string
	ResolvedAt   *time.Time
	CreatedBy    uuid.UUID `gorm:"type:uuid;not null"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (AgreedAction) TableName() string { return "agreed_actions" }

type InspectionComment struct {
	ID           uuid.UUID  `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
	InspectionID uuid.UUID  `gorm:"type:uuid;not null"`
	AuthorID     uuid.UUID  `gorm:"type:uuid;not null"`
	Body         string     `gorm:"not null"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
	DeletedAt    *time.Time `gorm:"index"`
}

func (InspectionComment) TableName() string { return "inspection_comments" }
EOF

cat > "${BASE}/internal/domain/errors.go" << 'EOF'
package domain

import "errors"

var (
	ErrNotFound            = errors.New("record not found")
	ErrUnauthorized        = errors.New("unauthorized")
	ErrForbidden           = errors.New("forbidden")
	ErrAlreadyExists       = errors.New("record already exists")
	ErrInvalidInput        = errors.New("invalid input")
	ErrInternalServer      = errors.New("internal server error")
	ErrInvalidTransition   = errors.New("invalid status transition")
	ErrChecklistIncomplete = errors.New("checklist has unanswered items")
)
EOF

log "Domain layer done"

# =============================================================================
# 3. DTOs
# =============================================================================
info "Writing DTOs..."

cat > "${BASE}/internal/dto/request/inspection_request.go" << 'EOF'
package request

// CreateInspectionRequest creates a new inspection.
type CreateInspectionRequest struct {
	ProjectName   string   `json:"project_name"  binding:"required,min=2,max=200"`
	LocationName  string   `json:"location_name"`
	Latitude      *float64 `json:"latitude"`
	Longitude     *float64 `json:"longitude"`
	ChecklistID   string   `json:"checklist_id"` // optional — links a template
	Notes         string   `json:"notes"`
}

// UpdateInspectionRequest updates editable fields on a draft inspection.
type UpdateInspectionRequest struct {
	ProjectName  string   `json:"project_name"  binding:"omitempty,min=2,max=200"`
	LocationName string   `json:"location_name"`
	Latitude     *float64 `json:"latitude"`
	Longitude    *float64 `json:"longitude"`
	Notes        string   `json:"notes"`
}

// TransitionStatusRequest moves an inspection to the next status.
type TransitionStatusRequest struct {
	Status string `json:"status" binding:"required"`
}

// ListInspectionsRequest holds query params for the inspection list.
type ListInspectionsRequest struct {
	Status  string `form:"status"`
	Search  string `form:"search"`
	Page    int    `form:"page,default=1"`
	Limit   int    `form:"limit,default=20"`
}
EOF

cat > "${BASE}/internal/dto/request/checklist_request.go" << 'EOF'
package request

// CreateTemplateRequest creates a new checklist template.
type CreateTemplateRequest struct {
	Name        string                   `json:"name"        binding:"required,min=2,max=200"`
	Description string                   `json:"description"`
	Items       []CreateTemplateItemRequest `json:"items" binding:"required,min=1,dive"`
}

type CreateTemplateItemRequest struct {
	Description string `json:"description" binding:"required"`
	SortOrder   int    `json:"sort_order"`
}

// CloneTemplateRequest clones a system template into the org's schema.
type CloneTemplateRequest struct {
	SystemTemplateID string `json:"system_template_id" binding:"required,uuid"`
	Name             string `json:"name"               binding:"omitempty,min=2,max=200"`
}

// UpdateChecklistItemRequest responds to a single checklist item.
type UpdateChecklistItemRequest struct {
	Response *bool  `json:"response"` // true=yes, false=no, null=unanswered
	Comment  string `json:"comment"`
}

// AddChecklistItemRequest adds an ad-hoc item to an inspection.
type AddChecklistItemRequest struct {
	Description string `json:"description" binding:"required"`
	SortOrder   int    `json:"sort_order"`
}
EOF

cat > "${BASE}/internal/dto/request/action_request.go" << 'EOF'
package request

// CreateActionRequest creates an agreed action on an inspection.
type CreateActionRequest struct {
	Description string `json:"description"  binding:"required"`
	AssigneeID  string `json:"assignee_id"  binding:"required,uuid"`
	DueDate     string `json:"due_date"     binding:"required"` // RFC3339
}

// UpdateActionRequest updates an action's status or evidence.
type UpdateActionRequest struct {
	Status      string `json:"status"       binding:"omitempty,oneof=pending in_progress resolved"`
	EvidenceURL string `json:"evidence_url"`
}

// AddCommentRequest adds a review comment to an inspection.
type AddCommentRequest struct {
	Body string `json:"body" binding:"required,min=1"`
}
EOF

cat > "${BASE}/internal/dto/response/inspection_response.go" << 'EOF'
package response

import "time"

type InspectionResponse struct {
	ID             string     `json:"id"`
	ProjectName    string     `json:"project_name"`
	LocationName   string     `json:"location_name"`
	Latitude       *float64   `json:"latitude,omitempty"`
	Longitude      *float64   `json:"longitude,omitempty"`
	Date           time.Time  `json:"date"`
	InspectorName  string     `json:"inspector_name"`
	InspectorRole  string     `json:"inspector_role"`
	AssignedUserID string     `json:"assigned_user_id"`
	ChecklistID    *string    `json:"checklist_id,omitempty"`
	Status         string     `json:"status"`
	Notes          string     `json:"notes,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`

	// Optional — loaded on detail view
	ChecklistItems []ChecklistItemResponse  `json:"checklist_items,omitempty"`
	AgreedActions  []ActionResponse         `json:"agreed_actions,omitempty"`
	Comments       []CommentResponse        `json:"comments,omitempty"`

	// Summary counts for list view
	TotalItems      *int `json:"total_items,omitempty"`
	AnsweredItems   *int `json:"answered_items,omitempty"`
	PendingActions  *int `json:"pending_actions,omitempty"`
}

type InspectionListResponse struct {
	Inspections []InspectionResponse `json:"inspections"`
	Total       int64                `json:"total"`
	Page        int                  `json:"page"`
	Limit       int                  `json:"limit"`
	TotalPages  int                  `json:"total_pages"`
}

type ChecklistItemResponse struct {
	ID          string  `json:"id"`
	Description string  `json:"description"`
	Response    *bool   `json:"response"`
	Comment     string  `json:"comment,omitempty"`
	SortOrder   int     `json:"sort_order"`
}

type ActionResponse struct {
	ID          string     `json:"id"`
	Description string     `json:"description"`
	AssigneeID  string     `json:"assignee_id"`
	DueDate     time.Time  `json:"due_date"`
	Status      string     `json:"status"`
	EvidenceURL string     `json:"evidence_url,omitempty"`
	ResolvedAt  *time.Time `json:"resolved_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

type CommentResponse struct {
	ID        string    `json:"id"`
	AuthorID  string    `json:"author_id"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

type ChecklistTemplateResponse struct {
	ID          string                      `json:"id"`
	Name        string                      `json:"name"`
	Description string                      `json:"description,omitempty"`
	IsSystem    bool                        `json:"is_system"`
	CreatedBy   string                      `json:"created_by"`
	CreatedAt   time.Time                   `json:"created_at"`
	Items       []TemplateItemResponse      `json:"items,omitempty"`
}

type TemplateItemResponse struct {
	ID          string `json:"id"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
}

type DashboardResponse struct {
	Total          int64                `json:"total"`
	Draft          int64                `json:"draft"`
	InProgress     int64                `json:"in_progress"`
	Submitted      int64                `json:"submitted"`
	UnderReview    int64                `json:"under_review"`
	PendingActions int64                `json:"pending_actions"`
	Completed      int64                `json:"completed"`
	Finalized      int64                `json:"finalized"`
	Recent         []InspectionResponse `json:"recent"`
}
EOF

log "DTOs done"

# =============================================================================
# 4. REPOSITORY INTERFACES
# =============================================================================
info "Writing repository interfaces..."

cat > "${BASE}/internal/repository/interface/inspection_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
)

type InspectionRepository interface {
	Create(ctx context.Context, inspection *domain.Inspection) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.Inspection, error)
	FindByIDWithDetails(ctx context.Context, id uuid.UUID) (*domain.Inspection, error)
	Update(ctx context.Context, inspection *domain.Inspection) error
	SoftDelete(ctx context.Context, id uuid.UUID) error
	List(ctx context.Context, filters ListFilters) ([]domain.Inspection, int64, error)
	Dashboard(ctx context.Context, userID uuid.UUID, role string) (*DashboardCounts, error)
}

type ListFilters struct {
	Status  string
	Search  string
	UserID  uuid.UUID
	Role    string
	Limit   int
	Offset  int
}

type DashboardCounts struct {
	Total          int64
	Draft          int64
	InProgress     int64
	Submitted      int64
	UnderReview    int64
	PendingActions int64
	Completed      int64
	Finalized      int64
}
EOF

cat > "${BASE}/internal/repository/interface/checklist_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
)

type ChecklistRepository interface {
	// Templates
	CreateTemplate(ctx context.Context, t *domain.ChecklistTemplate) error
	FindTemplateByID(ctx context.Context, id uuid.UUID) (*domain.ChecklistTemplate, error)
	ListTemplates(ctx context.Context) ([]domain.ChecklistTemplate, error)
	DeleteTemplate(ctx context.Context, id uuid.UUID) error

	// Checklist items on inspections
	CreateItems(ctx context.Context, items []domain.ChecklistItem) error
	FindItemsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.ChecklistItem, error)
	UpdateItem(ctx context.Context, item *domain.ChecklistItem) error
	AddItem(ctx context.Context, item *domain.ChecklistItem) error
}
EOF

cat > "${BASE}/internal/repository/interface/action_repository.go" << 'EOF'
package irepository

import (
	"context"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
)

type ActionRepository interface {
	Create(ctx context.Context, action *domain.AgreedAction) error
	FindByID(ctx context.Context, id uuid.UUID) (*domain.AgreedAction, error)
	FindByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.AgreedAction, error)
	Update(ctx context.Context, action *domain.AgreedAction) error

	// Comments
	AddComment(ctx context.Context, comment *domain.InspectionComment) error
	FindCommentsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.InspectionComment, error)
}
EOF

log "Repository interfaces done"

# =============================================================================
# 5. POSTGRES IMPLEMENTATIONS
# =============================================================================
info "Writing postgres implementations..."

cat > "${BASE}/internal/repository/postgres/inspection_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/ecocomply/inspection-service/internal/domain"
	irepository "github.com/ecocomply/inspection-service/internal/repository/interface"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type inspectionRepository struct {
	db *gorm.DB
}

func NewInspectionRepository(db *gorm.DB) *inspectionRepository {
	return &inspectionRepository{db: db}
}

func (r *inspectionRepository) Create(ctx context.Context, i *domain.Inspection) error {
	return r.db.WithContext(ctx).Create(i).Error
}

func (r *inspectionRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Inspection, error) {
	var i domain.Inspection
	result := r.db.WithContext(ctx).
		Where("id = ? AND deleted_at IS NULL", id).
		First(&i)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &i, result.Error
}

func (r *inspectionRepository) FindByIDWithDetails(ctx context.Context, id uuid.UUID) (*domain.Inspection, error) {
	var i domain.Inspection
	result := r.db.WithContext(ctx).
		Preload("ChecklistItems").
		Preload("AgreedActions").
		Preload("Comments").
		Where("id = ? AND deleted_at IS NULL", id).
		First(&i)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &i, result.Error
}

func (r *inspectionRepository) Update(ctx context.Context, i *domain.Inspection) error {
	return r.db.WithContext(ctx).Save(i).Error
}

func (r *inspectionRepository) SoftDelete(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).
		Model(&domain.Inspection{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}

func (r *inspectionRepository) List(ctx context.Context, f irepository.ListFilters) ([]domain.Inspection, int64, error) {
	var items []domain.Inspection
	var total int64

	q := r.db.WithContext(ctx).Model(&domain.Inspection{}).
		Where("deleted_at IS NULL")

	// Role-based scoping
	if f.Role == "enumerator" {
		q = q.Where("assigned_user_id = ?", f.UserID)
	}

	// Status filter
	if f.Status != "" {
		q = q.Where("status = ?", f.Status)
	}

	// Search
	if f.Search != "" {
		term := "%" + strings.ToLower(f.Search) + "%"
		q = q.Where("LOWER(project_name) LIKE ? OR LOWER(location_name) LIKE ?", term, term)
	}

	q.Count(&total)

	result := q.Order("created_at DESC").
		Limit(f.Limit).Offset(f.Offset).
		Find(&items)

	return items, total, result.Error
}

func (r *inspectionRepository) Dashboard(ctx context.Context, userID uuid.UUID, role string) (*irepository.DashboardCounts, error) {
	baseQ := "SELECT COUNT(*) FROM inspections WHERE deleted_at IS NULL"
	scopeQ := ""
	if role == "enumerator" {
		scopeQ = fmt.Sprintf(" AND assigned_user_id = '%s'", userID)
	}

	counts := &irepository.DashboardCounts{}
	statuses := []struct {
		field *int64
		status string
	}{
		{&counts.Total, ""},
		{&counts.Draft, "draft"},
		{&counts.InProgress, "in_progress"},
		{&counts.Submitted, "submitted"},
		{&counts.UnderReview, "under_review"},
		{&counts.PendingActions, "pending_actions"},
		{&counts.Completed, "completed"},
		{&counts.Finalized, "finalized"},
	}

	for _, s := range statuses {
		q := baseQ + scopeQ
		if s.status != "" {
			q += fmt.Sprintf(" AND status = '%s'", s.status)
		}
		r.db.WithContext(ctx).Raw(q).Scan(s.field)
	}

	return counts, nil
}
EOF

cat > "${BASE}/internal/repository/postgres/checklist_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type checklistRepository struct {
	db *gorm.DB
}

func NewChecklistRepository(db *gorm.DB) *checklistRepository {
	return &checklistRepository{db: db}
}

func (r *checklistRepository) CreateTemplate(ctx context.Context, t *domain.ChecklistTemplate) error {
	return r.db.WithContext(ctx).Create(t).Error
}

func (r *checklistRepository) FindTemplateByID(ctx context.Context, id uuid.UUID) (*domain.ChecklistTemplate, error) {
	var t domain.ChecklistTemplate
	result := r.db.WithContext(ctx).
		Preload("Items").
		Where("id = ? AND deleted_at IS NULL", id).
		First(&t)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &t, result.Error
}

func (r *checklistRepository) ListTemplates(ctx context.Context) ([]domain.ChecklistTemplate, error) {
	var templates []domain.ChecklistTemplate
	result := r.db.WithContext(ctx).
		Preload("Items").
		Where("deleted_at IS NULL").
		Order("is_system DESC, name ASC").
		Find(&templates)
	return templates, result.Error
}

func (r *checklistRepository) DeleteTemplate(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).
		Model(&domain.ChecklistTemplate{}).
		Where("id = ?", id).
		Update("deleted_at", "NOW()").Error
}

func (r *checklistRepository) CreateItems(ctx context.Context, items []domain.ChecklistItem) error {
	if len(items) == 0 {
		return nil
	}
	return r.db.WithContext(ctx).CreateInBatches(items, 100).Error
}

func (r *checklistRepository) FindItemsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.ChecklistItem, error) {
	var items []domain.ChecklistItem
	result := r.db.WithContext(ctx).
		Where("inspection_id = ?", inspectionID).
		Order("sort_order ASC").
		Find(&items)
	return items, result.Error
}

func (r *checklistRepository) UpdateItem(ctx context.Context, item *domain.ChecklistItem) error {
	return r.db.WithContext(ctx).Save(item).Error
}

func (r *checklistRepository) AddItem(ctx context.Context, item *domain.ChecklistItem) error {
	return r.db.WithContext(ctx).Create(item).Error
}
EOF

cat > "${BASE}/internal/repository/postgres/action_repo.go" << 'EOF'
package postgres

import (
	"context"
	"errors"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type actionRepository struct {
	db *gorm.DB
}

func NewActionRepository(db *gorm.DB) *actionRepository {
	return &actionRepository{db: db}
}

func (r *actionRepository) Create(ctx context.Context, a *domain.AgreedAction) error {
	return r.db.WithContext(ctx).Create(a).Error
}

func (r *actionRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.AgreedAction, error) {
	var a domain.AgreedAction
	result := r.db.WithContext(ctx).Where("id = ?", id).First(&a)
	if errors.Is(result.Error, gorm.ErrRecordNotFound) {
		return nil, domain.ErrNotFound
	}
	return &a, result.Error
}

func (r *actionRepository) FindByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.AgreedAction, error) {
	var actions []domain.AgreedAction
	result := r.db.WithContext(ctx).
		Where("inspection_id = ?", inspectionID).
		Order("due_date ASC").
		Find(&actions)
	return actions, result.Error
}

func (r *actionRepository) Update(ctx context.Context, a *domain.AgreedAction) error {
	return r.db.WithContext(ctx).Save(a).Error
}

func (r *actionRepository) AddComment(ctx context.Context, c *domain.InspectionComment) error {
	return r.db.WithContext(ctx).Create(c).Error
}

func (r *actionRepository) FindCommentsByInspectionID(ctx context.Context, inspectionID uuid.UUID) ([]domain.InspectionComment, error) {
	var comments []domain.InspectionComment
	result := r.db.WithContext(ctx).
		Where("inspection_id = ? AND deleted_at IS NULL", inspectionID).
		Order("created_at ASC").
		Find(&comments)
	return comments, result.Error
}
EOF

log "Postgres repositories done"

# =============================================================================
# 6. SERVICE LAYER
# =============================================================================
info "Writing service layer..."

cat > "${BASE}/internal/service/inspection_service.go" << 'EOF'
package service

import (
	"context"
	"time"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/ecocomply/inspection-service/internal/dto/request"
	"github.com/ecocomply/inspection-service/internal/dto/response"
	irepository "github.com/ecocomply/inspection-service/internal/repository/interface"
	"github.com/google/uuid"
)

type InspectionService struct {
	inspectionRepo irepository.InspectionRepository
	checklistRepo  irepository.ChecklistRepository
	actionRepo     irepository.ActionRepository
}

func NewInspectionService(
	inspectionRepo irepository.InspectionRepository,
	checklistRepo irepository.ChecklistRepository,
	actionRepo irepository.ActionRepository,
) *InspectionService {
	return &InspectionService{
		inspectionRepo: inspectionRepo,
		checklistRepo:  checklistRepo,
		actionRepo:     actionRepo,
	}
}

// --- Dashboard ---

func (s *InspectionService) Dashboard(ctx context.Context, userID uuid.UUID, role, inspectorName, inspectorRole string) (*response.DashboardResponse, error) {
	counts, err := s.inspectionRepo.Dashboard(ctx, userID, role)
	if err != nil {
		return nil, err
	}

	// Recent 5 inspections
	recent, _, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		UserID: userID,
		Role:   role,
		Limit:  5,
		Offset: 0,
	})
	if err != nil {
		return nil, err
	}

	var recentRes []response.InspectionResponse
	for _, i := range recent {
		recentRes = append(recentRes, toInspectionResponse(&i, false))
	}

	return &response.DashboardResponse{
		Total:          counts.Total,
		Draft:          counts.Draft,
		InProgress:     counts.InProgress,
		Submitted:      counts.Submitted,
		UnderReview:    counts.UnderReview,
		PendingActions: counts.PendingActions,
		Completed:      counts.Completed,
		Finalized:      counts.Finalized,
		Recent:         recentRes,
	}, nil
}

// --- Inspections ---

func (s *InspectionService) Create(ctx context.Context, userID uuid.UUID, inspectorName, inspectorRole string, req request.CreateInspectionRequest) (*response.InspectionResponse, error) {
	inspection := &domain.Inspection{
		ProjectName:    req.ProjectName,
		LocationName:   req.LocationName,
		Latitude:       req.Latitude,
		Longitude:      req.Longitude,
		Date:           time.Now(),
		InspectorName:  inspectorName,
		InspectorRole:  inspectorRole,
		AssignedUserID: userID,
		Notes:          req.Notes,
		Status:         domain.StatusDraft,
	}

	// Attach checklist template if provided
	if req.ChecklistID != "" {
		templateID, err := uuid.Parse(req.ChecklistID)
		if err != nil {
			return nil, domain.ErrInvalidInput
		}
		inspection.ChecklistID = &templateID
	}

	if err := s.inspectionRepo.Create(ctx, inspection); err != nil {
		return nil, err
	}

	// If a template was provided, copy its items onto this inspection
	if inspection.ChecklistID != nil {
		template, err := s.checklistRepo.FindTemplateByID(ctx, *inspection.ChecklistID)
		if err == nil && len(template.Items) > 0 {
			var items []domain.ChecklistItem
			for _, ti := range template.Items {
				tid := ti.ID
				items = append(items, domain.ChecklistItem{
					InspectionID:   inspection.ID,
					TemplateItemID: &tid,
					Description:    ti.Description,
					SortOrder:      ti.SortOrder,
				})
			}
			_ = s.checklistRepo.CreateItems(ctx, items)
		}
	}

	res := toInspectionResponse(inspection, false)
	return &res, nil
}

func (s *InspectionService) GetByID(ctx context.Context, id uuid.UUID) (*response.InspectionResponse, error) {
	inspection, err := s.inspectionRepo.FindByIDWithDetails(ctx, id)
	if err != nil {
		return nil, err
	}
	res := toInspectionResponse(inspection, true)
	return &res, nil
}

func (s *InspectionService) Update(ctx context.Context, id uuid.UUID, req request.UpdateInspectionRequest) (*response.InspectionResponse, error) {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if inspection.Status != domain.StatusDraft && inspection.Status != domain.StatusInProgress {
		return nil, domain.ErrForbidden
	}

	if req.ProjectName != "" {
		inspection.ProjectName = req.ProjectName
	}
	if req.LocationName != "" {
		inspection.LocationName = req.LocationName
	}
	if req.Latitude != nil {
		inspection.Latitude = req.Latitude
	}
	if req.Longitude != nil {
		inspection.Longitude = req.Longitude
	}
	if req.Notes != "" {
		inspection.Notes = req.Notes
	}

	if err := s.inspectionRepo.Update(ctx, inspection); err != nil {
		return nil, err
	}
	res := toInspectionResponse(inspection, false)
	return &res, nil
}

func (s *InspectionService) TransitionStatus(ctx context.Context, id uuid.UUID, req request.TransitionStatusRequest) (*response.InspectionResponse, error) {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}

	next := domain.InspectionStatus(req.Status)
	if !inspection.Status.CanTransitionTo(next) {
		return nil, domain.ErrInvalidTransition
	}

	inspection.Status = next
	if err := s.inspectionRepo.Update(ctx, inspection); err != nil {
		return nil, err
	}
	res := toInspectionResponse(inspection, false)
	return &res, nil
}

func (s *InspectionService) Delete(ctx context.Context, id uuid.UUID) error {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return err
	}
	if inspection.Status != domain.StatusDraft {
		return domain.ErrForbidden
	}
	return s.inspectionRepo.SoftDelete(ctx, id)
}

func (s *InspectionService) List(ctx context.Context, userID uuid.UUID, role string, req request.ListInspectionsRequest) (*response.InspectionListResponse, error) {
	if req.Limit <= 0 || req.Limit > 100 {
		req.Limit = 20
	}
	if req.Page <= 0 {
		req.Page = 1
	}
	offset := (req.Page - 1) * req.Limit

	inspections, total, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		Status: req.Status,
		Search: req.Search,
		UserID: userID,
		Role:   role,
		Limit:  req.Limit,
		Offset: offset,
	})
	if err != nil {
		return nil, err
	}

	var res []response.InspectionResponse
	for _, i := range inspections {
		res = append(res, toInspectionResponse(&i, false))
	}

	totalPages := int(total) / req.Limit
	if int(total)%req.Limit != 0 {
		totalPages++
	}

	return &response.InspectionListResponse{
		Inspections: res,
		Total:       total,
		Page:        req.Page,
		Limit:       req.Limit,
		TotalPages:  totalPages,
	}, nil
}

// --- Checklist ---

func (s *InspectionService) CreateTemplate(ctx context.Context, userID uuid.UUID, req request.CreateTemplateRequest) (*response.ChecklistTemplateResponse, error) {
	template := &domain.ChecklistTemplate{
		Name:        req.Name,
		Description: req.Description,
		IsSystem:    false,
		CreatedBy:   userID,
	}
	for i, item := range req.Items {
		template.Items = append(template.Items, domain.ChecklistTemplateItem{
			Description: item.Description,
			SortOrder:   i,
		})
	}
	if err := s.checklistRepo.CreateTemplate(ctx, template); err != nil {
		return nil, err
	}
	res := toTemplateResponse(template)
	return &res, nil
}

func (s *InspectionService) ListTemplates(ctx context.Context) ([]response.ChecklistTemplateResponse, error) {
	templates, err := s.checklistRepo.ListTemplates(ctx)
	if err != nil {
		return nil, err
	}
	var res []response.ChecklistTemplateResponse
	for _, t := range templates {
		res = append(res, toTemplateResponse(&t))
	}
	return res, nil
}

func (s *InspectionService) UpdateChecklistItem(ctx context.Context, itemID uuid.UUID, req request.UpdateChecklistItemRequest) (*response.ChecklistItemResponse, error) {
	items, err := s.checklistRepo.FindItemsByInspectionID(ctx, itemID)
	if err != nil || len(items) == 0 {
		return nil, domain.ErrNotFound
	}
	// itemID here is the checklist item ID directly
	item := &domain.ChecklistItem{ID: itemID}
	item.Response = req.Response
	item.Comment = req.Comment
	if err := s.checklistRepo.UpdateItem(ctx, item); err != nil {
		return nil, err
	}
	res := toChecklistItemResponse(item)
	return &res, nil
}

func (s *InspectionService) AddChecklistItem(ctx context.Context, inspectionID uuid.UUID, req request.AddChecklistItemRequest) (*response.ChecklistItemResponse, error) {
	item := &domain.ChecklistItem{
		InspectionID: inspectionID,
		Description:  req.Description,
		SortOrder:    req.SortOrder,
	}
	if err := s.checklistRepo.AddItem(ctx, item); err != nil {
		return nil, err
	}
	res := toChecklistItemResponse(item)
	return &res, nil
}

// --- Actions ---

func (s *InspectionService) CreateAction(ctx context.Context, inspectionID, createdBy uuid.UUID, req request.CreateActionRequest) (*response.ActionResponse, error) {
	assigneeID, err := uuid.Parse(req.AssigneeID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	dueDate, err := time.Parse(time.RFC3339, req.DueDate)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	action := &domain.AgreedAction{
		InspectionID: inspectionID,
		Description:  req.Description,
		AssigneeID:   assigneeID,
		DueDate:      dueDate,
		Status:       domain.ActionPending,
		CreatedBy:    createdBy,
	}
	if err := s.actionRepo.Create(ctx, action); err != nil {
		return nil, err
	}
	res := toActionResponse(action)
	return &res, nil
}

func (s *InspectionService) UpdateAction(ctx context.Context, actionID uuid.UUID, req request.UpdateActionRequest) (*response.ActionResponse, error) {
	action, err := s.actionRepo.FindByID(ctx, actionID)
	if err != nil {
		return nil, err
	}
	if req.Status != "" {
		action.Status = domain.ActionStatus(req.Status)
		if action.Status == domain.ActionResolved {
			now := time.Now()
			action.ResolvedAt = &now
		}
	}
	if req.EvidenceURL != "" {
		action.EvidenceURL = req.EvidenceURL
	}
	if err := s.actionRepo.Update(ctx, action); err != nil {
		return nil, err
	}
	res := toActionResponse(action)
	return &res, nil
}

func (s *InspectionService) AddComment(ctx context.Context, inspectionID, authorID uuid.UUID, req request.AddCommentRequest) (*response.CommentResponse, error) {
	comment := &domain.InspectionComment{
		InspectionID: inspectionID,
		AuthorID:     authorID,
		Body:         req.Body,
	}
	if err := s.actionRepo.AddComment(ctx, comment); err != nil {
		return nil, err
	}
	res := toCommentResponse(comment)
	return &res, nil
}

// --- mappers ---

func toInspectionResponse(i *domain.Inspection, withDetails bool) response.InspectionResponse {
	var checklistID *string
	if i.ChecklistID != nil {
		s := i.ChecklistID.String()
		checklistID = &s
	}
	res := response.InspectionResponse{
		ID:             i.ID.String(),
		ProjectName:    i.ProjectName,
		LocationName:   i.LocationName,
		Latitude:       i.Latitude,
		Longitude:      i.Longitude,
		Date:           i.Date,
		InspectorName:  i.InspectorName,
		InspectorRole:  i.InspectorRole,
		AssignedUserID: i.AssignedUserID.String(),
		ChecklistID:    checklistID,
		Status:         string(i.Status),
		Notes:          i.Notes,
		CreatedAt:      i.CreatedAt,
		UpdatedAt:      i.UpdatedAt,
	}
	if withDetails {
		for _, ci := range i.ChecklistItems {
			res.ChecklistItems = append(res.ChecklistItems, toChecklistItemResponse(&ci))
		}
		for _, a := range i.AgreedActions {
			res.AgreedActions = append(res.AgreedActions, toActionResponse(&a))
		}
		for _, c := range i.Comments {
			res.Comments = append(res.Comments, toCommentResponse(&c))
		}
	}
	return res
}

func toChecklistItemResponse(i *domain.ChecklistItem) response.ChecklistItemResponse {
	return response.ChecklistItemResponse{
		ID:          i.ID.String(),
		Description: i.Description,
		Response:    i.Response,
		Comment:     i.Comment,
		SortOrder:   i.SortOrder,
	}
}

func toActionResponse(a *domain.AgreedAction) response.ActionResponse {
	return response.ActionResponse{
		ID:          a.ID.String(),
		Description: a.Description,
		AssigneeID:  a.AssigneeID.String(),
		DueDate:     a.DueDate,
		Status:      string(a.Status),
		EvidenceURL: a.EvidenceURL,
		ResolvedAt:  a.ResolvedAt,
		CreatedAt:   a.CreatedAt,
	}
}

func toCommentResponse(c *domain.InspectionComment) response.CommentResponse {
	return response.CommentResponse{
		ID:        c.ID.String(),
		AuthorID:  c.AuthorID.String(),
		Body:      c.Body,
		CreatedAt: c.CreatedAt,
	}
}

func toTemplateResponse(t *domain.ChecklistTemplate) response.ChecklistTemplateResponse {
	res := response.ChecklistTemplateResponse{
		ID:          t.ID.String(),
		Name:        t.Name,
		Description: t.Description,
		IsSystem:    t.IsSystem,
		CreatedBy:   t.CreatedBy.String(),
		CreatedAt:   t.CreatedAt,
	}
	for _, item := range t.Items {
		res.Items = append(res.Items, response.TemplateItemResponse{
			ID:          item.ID.String(),
			Description: item.Description,
			SortOrder:   item.SortOrder,
		})
	}
	return res
}
EOF

log "Service layer done"

# =============================================================================
# 7. HANDLERS
# =============================================================================
info "Writing handlers..."

cat > "${BASE}/internal/handler/inspection_handler.go" << 'EOF'
package handler

import (
	"net/http"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/ecocomply/inspection-service/internal/dto/request"
	"github.com/ecocomply/inspection-service/internal/handler/middleware"
	"github.com/ecocomply/inspection-service/internal/service"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type InspectionHandler struct {
	svc *service.InspectionService
}

func NewInspectionHandler(svc *service.InspectionService) *InspectionHandler {
	return &InspectionHandler{svc: svc}
}

// GET /api/v1/inspections/dashboard
func (h *InspectionHandler) Dashboard(c *gin.Context) {
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)
	name := c.GetString(middleware.ContextUserName)

	res, err := h.svc.Dashboard(c.Request.Context(), userID, role, name, role)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "dashboard retrieved", res)
}

// GET /api/v1/inspections
func (h *InspectionHandler) List(c *gin.Context) {
	var req request.ListInspectionsRequest
	if err := c.ShouldBindQuery(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	role := c.GetString(middleware.ContextRole)

	res, err := h.svc.List(c.Request.Context(), userID, role, req)
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "inspections retrieved", res)
}

// POST /api/v1/inspections
func (h *InspectionHandler) Create(c *gin.Context) {
	var req request.CreateInspectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	name := c.GetString(middleware.ContextUserName)
	role := c.GetString(middleware.ContextRole)

	res, err := h.svc.Create(c.Request.Context(), userID, name, role, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "inspection created", res)
}

// GET /api/v1/inspections/:id
func (h *InspectionHandler) GetByID(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	res, err := h.svc.GetByID(c.Request.Context(), id)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "inspection retrieved", res)
}

// PATCH /api/v1/inspections/:id
func (h *InspectionHandler) Update(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.UpdateInspectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.Update(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "inspection updated", res)
}

// PATCH /api/v1/inspections/:id/status
func (h *InspectionHandler) TransitionStatus(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.TransitionStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.TransitionStatus(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "status updated", res)
}

// DELETE /api/v1/inspections/:id
func (h *InspectionHandler) Delete(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	if err := h.svc.Delete(c.Request.Context(), id); err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "inspection deleted", nil)
}

// POST /api/v1/inspections/:id/checklist
func (h *InspectionHandler) AddChecklistItem(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.AddChecklistItemRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.AddChecklistItem(c.Request.Context(), id, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "checklist item added", res)
}

// PATCH /api/v1/inspections/:id/checklist/:itemId
func (h *InspectionHandler) UpdateChecklistItem(c *gin.Context) {
	itemID, err := uuid.Parse(c.Param("itemId"))
	if err != nil {
		response.BadRequest(c, "invalid item id")
		return
	}
	var req request.UpdateChecklistItemRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.UpdateChecklistItem(c.Request.Context(), itemID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "checklist item updated", res)
}

// POST /api/v1/inspections/:id/actions
func (h *InspectionHandler) CreateAction(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.CreateActionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	createdBy, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.CreateAction(c.Request.Context(), id, createdBy, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "action created", res)
}

// PATCH /api/v1/inspections/:id/actions/:actionId
func (h *InspectionHandler) UpdateAction(c *gin.Context) {
	actionID, err := uuid.Parse(c.Param("actionId"))
	if err != nil {
		response.BadRequest(c, "invalid action id")
		return
	}
	var req request.UpdateActionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	res, err := h.svc.UpdateAction(c.Request.Context(), actionID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.OK(c, "action updated", res)
}

// POST /api/v1/inspections/:id/comments
func (h *InspectionHandler) AddComment(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid inspection id")
		return
	}
	var req request.AddCommentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	authorID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.AddComment(c.Request.Context(), id, authorID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "comment added", res)
}

// GET /api/v1/inspections/templates
func (h *InspectionHandler) ListTemplates(c *gin.Context) {
	res, err := h.svc.ListTemplates(c.Request.Context())
	if err != nil {
		response.InternalError(c, err.Error())
		return
	}
	response.OK(c, "templates retrieved", res)
}

// POST /api/v1/inspections/templates
func (h *InspectionHandler) CreateTemplate(c *gin.Context) {
	var req request.CreateTemplateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	userID, _ := uuid.Parse(c.GetString(middleware.ContextUserID))
	res, err := h.svc.CreateTemplate(c.Request.Context(), userID, req)
	if err != nil {
		handleErr(c, err)
		return
	}
	response.Created(c, "template created", res)
}

func handleErr(c *gin.Context, err error) {
	switch err {
	case domain.ErrNotFound:
		response.NotFound(c, err.Error())
	case domain.ErrForbidden:
		response.Forbidden(c, err.Error())
	case domain.ErrInvalidInput:
		response.BadRequest(c, err.Error())
	case domain.ErrInvalidTransition:
		c.JSON(http.StatusUnprocessableEntity, gin.H{"success": false, "error": err.Error()})
	default:
		response.InternalError(c, "something went wrong")
	}
}
EOF

log "Handlers done"

# =============================================================================
# 8. MIDDLEWARE — add ContextUserName
# =============================================================================
info "Updating auth middleware..."

cat > "${BASE}/internal/handler/middleware/auth.go" << 'EOF'
package middleware

import (
	"strings"

	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/ecocomply/shared/pkg/response"
	"github.com/gin-gonic/gin"
)

const (
	ContextUserID    = "user_id"
	ContextOrgID     = "org_id"
	ContextOrgSchema = "org_schema"
	ContextRole      = "role"
	ContextUserName  = "user_name"
)

func Auth(jwtManager *sharedjwt.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c)
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
		role, _ := c.Get(ContextRole)
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

func extractToken(c *gin.Context) string {
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

# =============================================================================
# 9. ROUTER
# =============================================================================
info "Writing router..."

cat > "${BASE}/internal/router/router.go" << 'EOF'
package router

import (
	"github.com/ecocomply/inspection-service/internal/di"
	"github.com/ecocomply/inspection-service/internal/handler"
	"github.com/ecocomply/inspection-service/internal/handler/middleware"
	"github.com/gin-gonic/gin"
)

func New(c *di.Container) *gin.Engine {
	if c.Config.Env == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.Logger())
	r.Use(middleware.CORS())

	r.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok", "service": "inspection-service"})
	})

	h := handler.NewInspectionHandler(c.InspectionService)

	v1 := r.Group("/api/v1/inspections")
	v1.Use(middleware.Auth(c.JWTManager))
	v1.Use(middleware.Tenant(c.DB))
	{
		// Dashboard
		v1.GET("/dashboard", h.Dashboard)

		// Templates — all authenticated users can read; org_admin creates
		v1.GET("/templates", h.ListTemplates)
		v1.POST("/templates", middleware.RequireRole("org_admin", "manager"), h.CreateTemplate)

		// Inspections
		v1.GET("", h.List)
		v1.POST("", h.Create)
		v1.GET("/:id", h.GetByID)
		v1.PATCH("/:id", h.Update)
		v1.DELETE("/:id", middleware.RequireRole("org_admin", "enumerator"), h.Delete)
		v1.PATCH("/:id/status", h.TransitionStatus)

		// Checklist items
		v1.POST("/:id/checklist", h.AddChecklistItem)
		v1.PATCH("/:id/checklist/:itemId", h.UpdateChecklistItem)

		// Actions
		v1.POST("/:id/actions", middleware.RequireRole("org_admin", "supervisor", "manager"), h.CreateAction)
		v1.PATCH("/:id/actions/:actionId", h.UpdateAction)

		// Comments
		v1.POST("/:id/comments", middleware.RequireRole("supervisor", "manager", "org_admin"), h.AddComment)
	}

	return r
}
EOF

log "Router done"

# =============================================================================
# 10. DI / WIRE
# =============================================================================
info "Writing DI container..."

cat > "${BASE}/internal/di/wire.go" << 'EOF'
package di

import (
	"fmt"

	"github.com/ecocomply/inspection-service/internal/config"
	irepository "github.com/ecocomply/inspection-service/internal/repository/interface"
	"github.com/ecocomply/inspection-service/internal/repository/postgres"
	"github.com/ecocomply/inspection-service/internal/service"
	sharedpostgres "github.com/ecocomply/shared/pkg/postgres"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	sharedjwt "github.com/ecocomply/shared/pkg/jwt"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Container struct {
	Config     *config.Config
	DB         *gorm.DB
	Redis      *redis.Client
	JWTManager *sharedjwt.Manager

	InspectionRepo irepository.InspectionRepository
	ChecklistRepo  irepository.ChecklistRepository
	ActionRepo     irepository.ActionRepository

	InspectionService *service.InspectionService
}

func NewContainer(cfg *config.Config) (*Container, error) {
	db, err := sharedpostgres.Connect(sharedpostgres.Config{
		Host:     cfg.DBHost,
		Port:     cfg.DBPort,
		User:     cfg.DBUser,
		Password: cfg.DBPassword,
		DBName:   cfg.DBName,
	})
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

	jwtManager := sharedjwt.NewManager(cfg.JWTSecret, cfg.JWTExpiryHrs)

	inspectionRepo := postgres.NewInspectionRepository(db)
	checklistRepo  := postgres.NewChecklistRepository(db)
	actionRepo     := postgres.NewActionRepository(db)

	inspectionSvc := service.NewInspectionService(inspectionRepo, checklistRepo, actionRepo)

	return &Container{
		Config:            cfg,
		DB:                db,
		Redis:             rdb,
		JWTManager:        jwtManager,
		InspectionRepo:    inspectionRepo,
		ChecklistRepo:     checklistRepo,
		ActionRepo:        actionRepo,
		InspectionService: inspectionSvc,
	}, nil
}
EOF

log "DI container done"

# =============================================================================
# 11. go.mod
# =============================================================================
info "Updating go.mod..."

cat > "${BASE}/go.mod" << 'EOF'
module github.com/ecocomply/inspection-service

go 1.22

require (
	github.com/ecocomply/shared v0.0.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.5.1
	github.com/rs/zerolog v1.32.0
	github.com/stretchr/testify v1.9.0
	gorm.io/driver/postgres v1.5.7
	gorm.io/gorm v1.25.9
)

replace github.com/ecocomply/shared => ../../shared
EOF

log "go.mod updated"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  inspection-service build complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Files written:"
find "${BASE}" -type f | sort | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "  1. cd ${BASE} && go mod tidy"
echo "  2. go build ./..."
echo ""
