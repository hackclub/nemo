CREATE TABLE fd.member_cluster (
    user_id     text        PRIMARY KEY,
    cluster_id  text        NOT NULL,
    accounts    integer     NOT NULL,
    ring        boolean     NOT NULL DEFAULT false,
    active      boolean     NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT member_cluster_accounts_positive CHECK (accounts >= 2)
);

CREATE INDEX member_cluster_cluster_idx ON fd.member_cluster (cluster_id);
CREATE INDEX member_cluster_ring_idx ON fd.member_cluster (cluster_id) WHERE ring;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.member_cluster TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.member_cluster TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_cluster FROM dbt_owner;
    END IF;
END
$$;
