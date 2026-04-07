DROP INDEX IF EXISTS idx_export_jobs_org_schema;
ALTER TABLE export_jobs
DROP COLUMN IF EXISTS org_schema;
