CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS app;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        CREATE ROLE pipeline_writer LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        CREATE ROLE dbt_owner LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        CREATE ROLE rails_app LOGIN;
    END IF;
END
$$;

-- pipeline
GRANT USAGE ON SCHEMA raw TO pipeline_writer;
GRANT INSERT, SELECT, UPDATE, DELETE ON ALL TABLES IN SCHEMA raw TO pipeline_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw GRANT INSERT, SELECT, UPDATE, DELETE ON TABLES TO pipeline_writer;
GRANT USAGE ON SCHEMA app TO pipeline_writer;

-- dbt
GRANT USAGE ON SCHEMA raw TO dbt_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA raw TO dbt_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw GRANT SELECT ON TABLES TO dbt_owner;
GRANT ALL ON SCHEMA analytics TO dbt_owner;

ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE SELECT ON TABLES FROM dbt_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE rails_app IN SCHEMA app REVOKE SELECT ON TABLES FROM dbt_owner;
REVOKE ALL ON ALL TABLES IN SCHEMA app FROM dbt_owner;
REVOKE ALL ON SCHEMA app FROM dbt_owner;

-- rails
GRANT ALL ON SCHEMA app TO rails_app;
GRANT USAGE ON SCHEMA analytics TO rails_app;

ALTER DEFAULT PRIVILEGES FOR ROLE rails_app IN SCHEMA app
    GRANT SELECT, UPDATE ON TABLES TO pipeline_writer;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'app' AND tablename = 'sync_request') THEN
        GRANT SELECT, UPDATE ON app.sync_request TO pipeline_writer;
    END IF;
END
$$;

