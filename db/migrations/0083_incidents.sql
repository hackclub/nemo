CREATE TABLE IF NOT EXISTS ingest.incident_ack (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_key text NOT NULL,
    kind text NOT NULL,
    acked_by text,
    acked_at timestamptz,
    muted_until timestamptz,
    note text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_key, kind)
);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT, INSERT, UPDATE ON ingest.incident_ack TO rails_app;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA ingest TO rails_app;
    END IF;
END
$$;

ALTER TABLE ingest.quality_result DROP CONSTRAINT IF EXISTS quality_result_run_id_fkey;
ALTER TABLE ingest.quality_result
    ADD CONSTRAINT quality_result_run_id_fkey
    FOREIGN KEY (run_id) REFERENCES raw.ingest_run (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS quality_result_subject_idx
    ON ingest.quality_result (subject, checked_at DESC);
CREATE INDEX IF NOT EXISTS quality_result_failing_idx
    ON ingest.quality_result (checked_at DESC) WHERE status = 'fail';
