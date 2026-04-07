CREATE OR REPLACE FUNCTION provision_org_schema(p_schema_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_schema TEXT := quote_ident(p_schema_name);
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %s', v_schema);
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS "pgcrypto"');

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.user_role AS ENUM ('org_admin', 'manager', 'supervisor', 'enumerator');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.inspection_status AS ENUM ('draft', 'in_progress', 'submitted', 'under_review', 'pending_actions', 'completed', 'finalized');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.action_status AS ENUM ('pending', 'in_progress', 'resolved', 'overdue');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.capture_source AS ENUM ('camera', 'gallery');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.gps_source AS ENUM ('device', 'manual', 'none');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.report_status AS ENUM ('generating', 'ready', 'failed');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.notification_status AS ENUM ('pending', 'sent', 'failed');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.export_job_status AS ENUM ('queued', 'running', 'done', 'failed');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.export_job_type AS ENUM ('db_backup', 'report_batch', 'media_export');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.review_stage AS ENUM ('supervisor', 'manager');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.review_status AS ENUM ('open', 'addressed', 'approved', 'rejected');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.permission_level AS ENUM ('viewer', 'editor', 'reviewer');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.access_status AS ENUM ('pending', 'active', 'revoked');
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE OR REPLACE FUNCTION %s.trigger_set_updated_at()
        RETURNS TRIGGER AS $fn$
        BEGIN
            NEW.updated_at = NOW();
            RETURN NEW;
        END;
        $fn$ LANGUAGE plpgsql
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.users (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role %s.user_role NOT NULL DEFAULT 'enumerator',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
            invited_by UUID,
            last_login_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at TIMESTAMPTZ,
            CONSTRAINT fk_invited_by FOREIGN KEY (invited_by) REFERENCES %s.users (id) ON DELETE SET NULL
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.password_reset_tokens (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TIMESTAMPTZ NOT NULL,
            used_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.refresh_tokens (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TIMESTAMPTZ NOT NULL,
            revoked_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.checklist_templates (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            name TEXT NOT NULL,
            description TEXT,
            is_system BOOLEAN NOT NULL DEFAULT FALSE,
            cloned_from UUID,
            created_by UUID NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at TIMESTAMPTZ
        )
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.checklist_template_items (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            template_id UUID NOT NULL REFERENCES %s.checklist_templates (id) ON DELETE CASCADE,
            description TEXT NOT NULL,
            sort_order INT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.inspections (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            project_name TEXT NOT NULL,
            location_name TEXT,
            latitude DOUBLE PRECISION,
            longitude DOUBLE PRECISION,
            date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            inspector_name TEXT NOT NULL,
            inspector_role TEXT NOT NULL,
            assigned_user_id UUID NOT NULL,
            checklist_id UUID REFERENCES %s.checklist_templates (id) ON DELETE SET NULL,
            status %s.inspection_status NOT NULL DEFAULT 'draft',
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at TIMESTAMPTZ
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.checklist_items (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL REFERENCES %s.inspections (id) ON DELETE CASCADE,
            template_item_id UUID,
            description TEXT NOT NULL,
            response BOOLEAN,
            comment TEXT,
            sort_order INT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.agreed_actions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL REFERENCES %s.inspections (id) ON DELETE CASCADE,
            description TEXT NOT NULL,
            assignee_id UUID NOT NULL,
            due_date TIMESTAMPTZ NOT NULL,
            status %s.action_status NOT NULL DEFAULT 'pending',
            evidence_url TEXT,
            resolved_at TIMESTAMPTZ,
            created_by UUID NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.inspection_comments (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL REFERENCES %s.inspections (id) ON DELETE CASCADE,
            author_id UUID NOT NULL,
            body TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at TIMESTAMPTZ
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.inspection_reviews (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL REFERENCES %s.inspections (id) ON DELETE CASCADE,
            stage %s.review_stage NOT NULL,
            reviewer_id UUID NOT NULL,
            assigned_to_id UUID NOT NULL,
            comment TEXT NOT NULL,
            due_date TIMESTAMPTZ NOT NULL,
            status %s.review_status NOT NULL DEFAULT 'open',
            response_comment TEXT,
            resolved_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.media (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL,
            uploaded_by UUID NOT NULL,
            cloudinary_id TEXT NOT NULL UNIQUE,
            url TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            size_bytes BIGINT NOT NULL DEFAULT 0,
            captured_via %s.capture_source NOT NULL,
            latitude DOUBLE PRECISION,
            longitude DOUBLE PRECISION,
            gps_source %s.gps_source NOT NULL DEFAULT 'none',
            captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            deleted_at TIMESTAMPTZ
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.reports (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL,
            generated_by UUID NOT NULL,
            status %s.report_status NOT NULL DEFAULT 'generating',
            file_url TEXT,
            file_size_bytes BIGINT,
            share_token TEXT UNIQUE,
            share_expiry TIMESTAMPTZ,
            error_message TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.collab_sessions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL UNIQUE,
            created_by UUID NOT NULL,
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.collab_participants (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            session_id UUID NOT NULL REFERENCES %s.collab_sessions (id) ON DELETE CASCADE,
            user_id UUID NOT NULL,
            joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            left_at TIMESTAMPTZ,
            UNIQUE (session_id, user_id)
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.collab_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            session_id UUID NOT NULL REFERENCES %s.collab_sessions (id) ON DELETE CASCADE,
            user_id UUID NOT NULL,
            event_type TEXT NOT NULL,
            payload JSONB,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.collab_access (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            inspection_id UUID NOT NULL,
            user_id UUID NOT NULL,
            permission %s.permission_level NOT NULL,
            status %s.access_status NOT NULL DEFAULT 'pending',
            invited_by UUID NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (inspection_id, user_id)
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.notifications (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            recipient_id UUID NOT NULL,
            type TEXT NOT NULL,
            subject TEXT NOT NULL,
            body TEXT NOT NULL,
            status %s.notification_status NOT NULL DEFAULT 'pending',
            sent_at TIMESTAMPTZ,
            error TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.export_jobs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            type %s.export_job_type NOT NULL,
            status %s.export_job_status NOT NULL DEFAULT 'queued',
            org_schema TEXT NOT NULL DEFAULT '',
            file_url TEXT,
            error TEXT,
            started_at TIMESTAMPTZ,
            finished_at TIMESTAMPTZ,
            created_by UUID NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_users_updated_at
                BEFORE UPDATE ON %s.users
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_inspections_updated_at
                BEFORE UPDATE ON %s.inspections
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_checklist_items_updated_at
                BEFORE UPDATE ON %s.checklist_items
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_agreed_actions_updated_at
                BEFORE UPDATE ON %s.agreed_actions
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_inspection_reviews_updated_at
                BEFORE UPDATE ON %s.inspection_reviews
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_reports_updated_at
                BEFORE UPDATE ON %s.reports
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_collab_sessions_updated_at
                BEFORE UPDATE ON %s.collab_sessions
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TRIGGER set_collab_access_updated_at
                BEFORE UPDATE ON %s.collab_access
                FOR EACH ROW
                EXECUTE FUNCTION %s.trigger_set_updated_at();
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema, v_schema);
END;
$$ LANGUAGE plpgsql;
