CREATE OR REPLACE FUNCTION public.provision_org_schema(schema_name TEXT)
RETURNS VOID AS $$
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', schema_name);

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
END;
$$ LANGUAGE plpgsql;
