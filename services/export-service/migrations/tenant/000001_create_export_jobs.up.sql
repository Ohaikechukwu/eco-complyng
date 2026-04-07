CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE export_job_status AS ENUM ('queued', 'running', 'done', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE export_job_type AS ENUM ('db_backup', 'report_batch', 'media_export');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS export_jobs (
    id          UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    type        export_job_type     NOT NULL,
    status      export_job_status   NOT NULL DEFAULT 'queued',
    file_url    TEXT,
    error       TEXT,
    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_by  UUID                NOT NULL,
    created_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_export_jobs_status     ON export_jobs (status);
CREATE INDEX IF NOT EXISTS idx_export_jobs_created_by ON export_jobs (created_by);
