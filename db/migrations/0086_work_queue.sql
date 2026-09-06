ALTER TABLE ingest.work_item ALTER COLUMN fetched DROP NOT NULL;
ALTER TABLE ingest.work_item ALTER COLUMN fetched DROP DEFAULT;
UPDATE ingest.work_item SET fetched = NULL WHERE fetched = 0 AND state = 'pending';

ALTER TABLE ingest.work_item
    ADD COLUMN IF NOT EXISTS worker text,
    ADD COLUMN IF NOT EXISTS worker_boot uuid,
    ADD COLUMN IF NOT EXISTS lease_until timestamptz,
    ADD COLUMN IF NOT EXISTS fence bigint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS settled_at timestamptz,
    ADD COLUMN IF NOT EXISTS note text;

ALTER TABLE ingest.work_item DROP CONSTRAINT IF EXISTS work_item_state_check;
ALTER TABLE ingest.work_item ADD CONSTRAINT work_item_state_check
    CHECK (state IN ('pending', 'claimed', 'complete', 'short', 'unavailable', 'dead'));

CREATE INDEX IF NOT EXISTS work_item_lease_idx
    ON ingest.work_item (lease_until) WHERE state = 'claimed';
CREATE INDEX IF NOT EXISTS work_item_target_idx
    ON ingest.work_item (work_kind, target_key);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON ingest.work_item TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON ingest.work_item TO pipeline_writer;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA ingest TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        GRANT SELECT ON ingest.work_item TO dbt_owner;
    END IF;
END
$$;
