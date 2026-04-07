-- =============================================================================
-- Migration: 000001_create_collaboration (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- TABLE: collab_sessions
-- One session per inspection — tracks active real-time collaboration
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collab_sessions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID        NOT NULL UNIQUE,
    created_by      UUID        NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cs_inspection_id ON collab_sessions (inspection_id);
CREATE INDEX IF NOT EXISTS idx_cs_is_active     ON collab_sessions (is_active);

-- -----------------------------------------------------------------------------
-- TABLE: collab_participants
-- Tracks who has joined a session
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collab_participants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at     TIMESTAMPTZ,
    UNIQUE (session_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_cp_session_id ON collab_participants (session_id);
CREATE INDEX IF NOT EXISTS idx_cp_user_id    ON collab_participants (user_id);

-- -----------------------------------------------------------------------------
-- TABLE: collab_events
-- Audit log of all real-time events in a session
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collab_events (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    event_type  TEXT        NOT NULL,
    payload     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ce_session_id  ON collab_events (session_id);
CREATE INDEX IF NOT EXISTS idx_ce_event_type  ON collab_events (event_type);
CREATE INDEX IF NOT EXISTS idx_ce_created_at  ON collab_events (created_at DESC);

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_collab_sessions_updated_at
    BEFORE UPDATE ON collab_sessions
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
