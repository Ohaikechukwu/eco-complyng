CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN
    CREATE TYPE notification_status AS ENUM ('pending', 'sent', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS notifications (
    id           UUID                  PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id UUID                  NOT NULL,
    type         TEXT                  NOT NULL,
    subject      TEXT                  NOT NULL,
    body         TEXT                  NOT NULL,
    status       notification_status   NOT NULL DEFAULT 'pending',
    sent_at      TIMESTAMPTZ,
    error        TEXT,
    created_at   TIMESTAMPTZ           NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON notifications (recipient_id);
CREATE INDEX IF NOT EXISTS idx_notifications_status    ON notifications (status);
CREATE INDEX IF NOT EXISTS idx_notifications_created   ON notifications (created_at DESC);
