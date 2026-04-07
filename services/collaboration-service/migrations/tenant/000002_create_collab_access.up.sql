DO $$ BEGIN
    CREATE TYPE permission_level AS ENUM ('viewer', 'editor', 'reviewer');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE access_status AS ENUM ('pending', 'active', 'revoked');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS collab_access (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id UUID NOT NULL,
    user_id       UUID NOT NULL,
    permission    permission_level NOT NULL,
    status        access_status NOT NULL DEFAULT 'pending',
    invited_by    UUID NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (inspection_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_collab_access_inspection_id ON collab_access (inspection_id);
CREATE INDEX IF NOT EXISTS idx_collab_access_user_id ON collab_access (user_id);

DO $$ BEGIN
    CREATE TRIGGER set_collab_access_updated_at
        BEFORE UPDATE ON collab_access
        FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
