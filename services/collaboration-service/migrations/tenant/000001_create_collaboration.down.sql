DROP TRIGGER IF EXISTS set_collab_sessions_updated_at ON collab_sessions;
DROP FUNCTION IF EXISTS trigger_set_updated_at();
DROP TABLE IF EXISTS collab_events;
DROP TABLE IF EXISTS collab_participants;
DROP TABLE IF EXISTS collab_sessions;
