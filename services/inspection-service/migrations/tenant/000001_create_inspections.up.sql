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
