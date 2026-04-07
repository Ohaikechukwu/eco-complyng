DO $$ BEGIN
    CREATE TYPE review_stage AS ENUM ('supervisor', 'manager');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE review_status AS ENUM ('open', 'addressed', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS inspection_reviews (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id    UUID NOT NULL REFERENCES inspections (id) ON DELETE CASCADE,
    stage            review_stage NOT NULL,
    reviewer_id      UUID NOT NULL,
    assigned_to_id   UUID NOT NULL,
    comment          TEXT NOT NULL,
    due_date         TIMESTAMPTZ NOT NULL,
    status           review_status NOT NULL DEFAULT 'open',
    response_comment TEXT,
    resolved_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ir_inspection_id ON inspection_reviews (inspection_id);
CREATE INDEX IF NOT EXISTS idx_ir_reviewer_id ON inspection_reviews (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_ir_assigned_to_id ON inspection_reviews (assigned_to_id);

DO $$ BEGIN
    CREATE TRIGGER set_inspection_reviews_updated_at
        BEFORE UPDATE ON inspection_reviews
        FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
