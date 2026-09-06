CREATE TABLE IF NOT EXISTS ingest.slice_coverage (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_key text NOT NULL,
    slice_key text NOT NULL,
    slice_start date,
    slice_end date,
    state text NOT NULL DEFAULT 'claimed'
        CHECK (state IN ('claimed', 'complete', 'short', 'superseded', 'unavailable')),
    expected integer,
    landed integer,
    run_id bigint REFERENCES raw.ingest_run (id) ON DELETE SET NULL,
    worker text,
    worker_boot uuid,
    lease_until timestamptz,
    fence bigint NOT NULL DEFAULT 0,
    attempts integer NOT NULL DEFAULT 0,
    note text,
    claimed_at timestamptz,
    settled_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_key, slice_key)
);

CREATE INDEX IF NOT EXISTS slice_coverage_source_state_idx
    ON ingest.slice_coverage (source_key, state);
CREATE INDEX IF NOT EXISTS slice_coverage_lease_idx
    ON ingest.slice_coverage (lease_until) WHERE lease_until IS NOT NULL;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON ingest.slice_coverage TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON ingest.slice_coverage TO pipeline_writer;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA ingest TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        GRANT SELECT ON ingest.slice_coverage TO dbt_owner;
    END IF;
END
$$;
