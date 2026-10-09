CREATE TABLE fd.ip_network (
    ip_prefix     inet        PRIMARY KEY,
    asn           integer,
    network       text,
    country       text,
    class         text        NOT NULL,
    source        text        NOT NULL,
    classified_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ip_network_class_known
        CHECK (class IN ('stable', 'rotating', 'vpn', 'hosting', 'tor')),
    CONSTRAINT ip_network_source_known
        CHECK (source IN ('anomaly', 'curated', 'lists_vpn', 'ipinfo', 'default'))
);

CREATE INDEX ip_network_classified_idx ON fd.ip_network (classified_at);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.ip_network TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.ip_network TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.ip_network FROM dbt_owner;
    END IF;
END
$$;
