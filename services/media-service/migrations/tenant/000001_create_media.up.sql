-- =============================================================================
-- Migration: 000001_create_media (TENANT SCHEMA)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- ENUM: capture source
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE capture_source AS ENUM ('camera', 'gallery');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- ENUM: gps source
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE gps_source AS ENUM ('device', 'manual', 'none');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- TABLE: media
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS media (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id   UUID            NOT NULL,
    uploaded_by     UUID            NOT NULL,
    cloudinary_id   TEXT            NOT NULL UNIQUE,
    url             TEXT            NOT NULL,
    filename        TEXT            NOT NULL,
    mime_type       TEXT            NOT NULL,
    size_bytes      BIGINT          NOT NULL DEFAULT 0,
    captured_via    capture_source  NOT NULL,
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,
    gps_source      gps_source      NOT NULL DEFAULT 'none',
    captured_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_media_inspection_id ON media (inspection_id);
CREATE INDEX IF NOT EXISTS idx_media_uploaded_by   ON media (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_media_deleted_at    ON media (deleted_at);
CREATE INDEX IF NOT EXISTS idx_media_captured_at   ON media (captured_at DESC);
