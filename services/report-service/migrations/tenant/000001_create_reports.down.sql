DROP TRIGGER IF EXISTS set_reports_updated_at ON reports;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE  IF EXISTS reports;
DROP TYPE   IF EXISTS report_status;
