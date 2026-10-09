CREATE TABLE IF NOT EXISTS ingest.table_size (
    day           date        NOT NULL,
    table_name    text        NOT NULL,
    bytes         bigint      NOT NULL,
    rows          bigint,
    grew          bigint,
    median_growth bigint,
    flagged       boolean     NOT NULL DEFAULT false,
    measured_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, table_name)
);

CREATE INDEX IF NOT EXISTS table_size_history_idx ON ingest.table_size (table_name, day DESC);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON ingest.table_size TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON ingest.table_size TO rails_app;
    END IF;
END
$$;
