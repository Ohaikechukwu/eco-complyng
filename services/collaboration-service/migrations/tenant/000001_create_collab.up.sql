CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS collab_sessions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID        NOT NULL UNIQUE,
    created_by      UUID        NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS collab_participants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (session_id, user_id)
);

CREATE TABLE IF NOT EXISTS collab_events (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID        NOT NULL REFERENCES collab_sessions (id) ON DELETE CASCADE,
    user_id         UUID        NOT NULL,
    event_type      TEXT        NOT NULL,
    payload         JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_collab_sessions_inspection ON collab_sessions (inspection_id);
CREATE INDEX IF NOT EXISTS idx_collab_events_session      ON collab_events (session_id);
CREATE INDEX IF NOT EXISTS idx_collab_events_created      ON collab_events (created_at DESC);
