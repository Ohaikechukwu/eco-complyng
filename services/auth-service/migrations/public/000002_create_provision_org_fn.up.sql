CREATE OR REPLACE FUNCTION provision_org_schema(p_schema_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_schema TEXT := quote_ident(p_schema_name);
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %s', v_schema);

    EXECUTE format($fmt$
        DO $inner$ BEGIN
            CREATE TYPE %s.user_role AS ENUM (
                'org_admin', 'manager', 'supervisor', 'enumerator'
            );
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $inner$;
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.users (
            id              UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
            name            TEXT             NOT NULL,
            email           TEXT             NOT NULL UNIQUE,
            password_hash   TEXT             NOT NULL,
            role            %s.user_role     NOT NULL DEFAULT 'enumerator',
            is_active       BOOLEAN          NOT NULL DEFAULT TRUE,
            invited_by      UUID,
            last_login_at   TIMESTAMPTZ,
            created_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
            updated_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
            deleted_at      TIMESTAMPTZ,
            CONSTRAINT fk_invited_by FOREIGN KEY (invited_by)
                REFERENCES %s.users (id) ON DELETE SET NULL
        )
    $fmt$, v_schema, v_schema, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_email      ON %s.users (email)',      v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_role       ON %s.users (role)',       v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON %s.users (deleted_at)', v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.password_reset_tokens (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID        NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash  TEXT        NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            used_at     TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format($fmt$
        CREATE TABLE IF NOT EXISTS %s.refresh_tokens (
            id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     UUID        NOT NULL REFERENCES %s.users (id) ON DELETE CASCADE,
            token_hash  TEXT        NOT NULL UNIQUE,
            expires_at  TIMESTAMPTZ NOT NULL,
            revoked_at  TIMESTAMPTZ,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $fmt$, v_schema, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_rt_user_id    ON %s.refresh_tokens (user_id)',        v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_rt_expires_at ON %s.refresh_tokens (expires_at)',     v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_prt_user_id   ON %s.password_reset_tokens (user_id)', v_schema);

    EXECUTE format($fmt$
        CREATE OR REPLACE FUNCTION %s.trigger_set_updated_at()
        RETURNS TRIGGER AS $fn$
        BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
        $fn$ LANGUAGE plpgsql
    $fmt$, v_schema);

    EXECUTE format($fmt$
        CREATE TRIGGER set_users_updated_at
            BEFORE UPDATE ON %s.users
            FOR EACH ROW
            EXECUTE FUNCTION %s.trigger_set_updated_at()
    $fmt$, v_schema, v_schema);
END;
$$ LANGUAGE plpgsql;
