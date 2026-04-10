CREATE OR REPLACE FUNCTION public.provision_org_schema(schema_name TEXT)
RETURNS VOID AS $$
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', schema_name);
    EXECUTE format('SET search_path TO %I, public', schema_name);

    -- ── auth-service tables ────────────────────────────────────────────
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.users (
            id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            name                 TEXT NOT NULL,
            email                TEXT NOT NULL UNIQUE,
            password_hash        TEXT NOT NULL,
            role                 TEXT NOT NULL DEFAULT ''org_member'',
            is_active            BOOLEAN NOT NULL DEFAULT TRUE,
            must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
            invited_by           UUID,
            last_login_at        TIMESTAMPTZ,
            created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at           TIMESTAMPTZ
        )', schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.refresh_tokens (
            id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID NOT NULL REFERENCES %I.users(id) ON DELETE CASCADE,
            token_hash  TEXT NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            revoked_at  TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name, schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.password_reset_tokens (
            id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID NOT NULL REFERENCES %I.users(id) ON DELETE CASCADE,
            token_hash  TEXT NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            used_at     TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name, schema_name);

    -- ── inspection-service tables ──────────────────────────────────────
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.checklist_templates (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            name        TEXT        NOT NULL,
            description TEXT,
            is_system   BOOLEAN     NOT NULL DEFAULT FALSE,
            cloned_from UUID,
            created_by  UUID        NOT NULL,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at  TIMESTAMPTZ
        )', schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.checklist_template_items (
            id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            template_id UUID NOT NULL REFERENCES %I.checklist_templates(id) ON DELETE CASCADE,
            description TEXT NOT NULL,
            sort_order  INT  NOT NULL DEFAULT 0,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name, schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.inspections (
            id               UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
            project_name     TEXT               NOT NULL,
            location_name    TEXT,
            latitude         DOUBLE PRECISION,
            longitude        DOUBLE PRECISION,
            date             TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
            inspector_name   TEXT               NOT NULL,
            inspector_role   TEXT               NOT NULL,
            assigned_user_id UUID               NOT NULL,
            checklist_id     UUID               REFERENCES %I.checklist_templates(id) ON DELETE SET NULL,
            status           TEXT               NOT NULL DEFAULT ''draft'',
            notes            TEXT,
            created_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
            updated_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
            deleted_at       TIMESTAMPTZ
        )', schema_name, schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.checklist_items (
            id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id    UUID NOT NULL REFERENCES %I.inspections(id) ON DELETE CASCADE,
            template_item_id UUID,
            description      TEXT NOT NULL,
            response         BOOLEAN,
            comment          TEXT,
            sort_order       INT  NOT NULL DEFAULT 0,
            created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name, schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.agreed_actions (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL REFERENCES %I.inspections(id) ON DELETE CASCADE,
            description   TEXT NOT NULL,
            assignee_id   UUID NOT NULL,
            due_date      TIMESTAMPTZ NOT NULL,
            status        TEXT NOT NULL DEFAULT ''pending'',
            evidence_url  TEXT,
            resolved_at   TIMESTAMPTZ,
            created_by    UUID NOT NULL,
            created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name, schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.inspection_comments (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL REFERENCES %I.inspections(id) ON DELETE CASCADE,
            author_id     UUID NOT NULL,
            body          TEXT NOT NULL,
            created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at    TIMESTAMPTZ
        )', schema_name, schema_name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.inspection_reviews (
            id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id    UUID NOT NULL REFERENCES %I.inspections(id) ON DELETE CASCADE,
            stage            TEXT NOT NULL,
            reviewer_id      UUID NOT NULL,
            assigned_to_id   UUID NOT NULL,
            comment          TEXT NOT NULL,
            due_date         TIMESTAMPTZ NOT NULL,
            status           TEXT NOT NULL DEFAULT ''open'',
            response_comment TEXT,
            resolved_at      TIMESTAMPTZ,
            created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name, schema_name);

    -- ── notification-service tables ────────────────────────────────────
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.notifications (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id    UUID NOT NULL,
            type       TEXT NOT NULL,
            title      TEXT NOT NULL,
            body       TEXT NOT NULL,
            read       BOOLEAN NOT NULL DEFAULT FALSE,
            meta       JSONB,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name);

    -- ── report-service tables ──────────────────────────────────────────
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.reports (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL,
            generated_by  UUID NOT NULL,
            format        TEXT NOT NULL DEFAULT ''pdf'',
            storage_key   TEXT NOT NULL,
            created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name);

    -- ── export-service tables ──────────────────────────────────────────
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.export_jobs (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            org_schema TEXT NOT NULL,
            user_id    UUID NOT NULL,
            type       TEXT NOT NULL,
            status     TEXT NOT NULL DEFAULT ''pending'',
            file_url   TEXT,
            error      TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name);

    -- ── media-service tables ───────────────────────────────────────────
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I.media (
            id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            uploaded_by  UUID NOT NULL,
            entity_type  TEXT NOT NULL,
            entity_id    UUID NOT NULL,
            filename     TEXT NOT NULL,
            storage_key  TEXT NOT NULL,
            content_type TEXT NOT NULL,
            size_bytes   BIGINT NOT NULL DEFAULT 0,
            created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )', schema_name);

END;
$$ LANGUAGE plpgsql;
