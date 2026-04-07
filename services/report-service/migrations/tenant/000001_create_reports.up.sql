-- =============================================================================
-- Migration: 000001_create_reports (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE report_status AS ENUM ('generating', 'ready', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS reports (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID            NOT NULL,
    generated_by    UUID            NOT NULL,
    status          report_status   NOT NULL DEFAULT 'generating',
    file_url        TEXT,
    file_size_bytes BIGINT,
    share_token     TEXT            UNIQUE,
    share_expiry    TIMESTAMPTZ,
    error_message   TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reports_inspection_id ON reports (inspection_id);
CREATE INDEX IF NOT EXISTS idx_reports_generated_by  ON reports (generated_by);
CREATE INDEX IF NOT EXISTS idx_reports_share_token   ON reports (share_token);
CREATE INDEX IF NOT EXISTS idx_reports_status        ON reports (status);

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_reports_updated_at
    BEFORE UPDATE ON reports
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
