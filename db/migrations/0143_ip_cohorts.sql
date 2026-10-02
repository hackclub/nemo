CREATE TABLE IF NOT EXISTS fd.ip_cohort (
    ip_prefix    inet        NOT NULL PRIMARY KEY,
    people       integer     NOT NULL,
    logins       integer     NOT NULL,
    first_seen   timestamptz,
    last_seen    timestamptz,
    refreshed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ip_cohort_crowded_idx ON fd.ip_cohort (people DESC);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.ip_cohort TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.ip_cohort TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.ip_cohort FROM dbt_owner;
    END IF;
END
$$;
