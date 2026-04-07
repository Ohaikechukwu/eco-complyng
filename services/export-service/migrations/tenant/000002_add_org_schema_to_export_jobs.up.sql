ALTER TABLE export_jobs
ADD COLUMN IF NOT EXISTS org_schema TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_export_jobs_org_schema ON export_jobs (org_schema);
