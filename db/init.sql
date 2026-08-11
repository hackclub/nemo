CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS fd;

DO $$
DECLARE
    may_create boolean;
    already_there boolean;
BEGIN
    SELECT coalesce(rolcreaterole, false) OR coalesce(rolsuper, false)
        INTO may_create FROM pg_roles WHERE rolname = current_user;
    SELECT count(*) = 3 INTO already_there
        FROM pg_roles WHERE rolname IN ('pipeline_writer', 'dbt_owner', 'rails_app');

    IF NOT already_there AND NOT coalesce(may_create, false) THEN
        RAISE NOTICE 'single-role deployment: % may not create roles, so pipeline_writer, '
            'dbt_owner and rails_app are skipped and every service shares %. '
            'write ownership is not enforced on this server', current_user, current_user;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        CREATE ROLE pipeline_writer LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        CREATE ROLE dbt_owner LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        CREATE ROLE rails_app LOGIN;
    END IF;

    EXECUTE 'GRANT USAGE ON SCHEMA raw TO pipeline_writer';
    EXECUTE 'GRANT INSERT, SELECT, UPDATE, DELETE, MAINTAIN ON ALL TABLES IN SCHEMA raw '
        'TO pipeline_writer';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA raw '
        'GRANT INSERT, SELECT, UPDATE, DELETE, MAINTAIN ON TABLES TO pipeline_writer';
    EXECUTE 'GRANT USAGE ON SCHEMA app TO pipeline_writer';
    EXECUTE 'GRANT USAGE ON SCHEMA fd TO pipeline_writer';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA fd '
        'TO pipeline_writer';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA fd '
        'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pipeline_writer';
    EXECUTE 'GRANT USAGE ON ALL SEQUENCES IN SCHEMA fd TO pipeline_writer';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA fd '
        'GRANT USAGE ON SEQUENCES TO pipeline_writer';

    EXECUTE 'GRANT USAGE ON SCHEMA raw TO dbt_owner';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA raw TO dbt_owner';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA raw GRANT SELECT ON TABLES TO dbt_owner';
    EXECUTE 'GRANT ALL ON SCHEMA analytics TO dbt_owner';
    EXECUTE 'GRANT USAGE ON SCHEMA fd TO dbt_owner';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA fd TO dbt_owner';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA fd GRANT SELECT ON TABLES TO dbt_owner';

    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE SELECT ON TABLES FROM dbt_owner';
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE rails_app IN SCHEMA app '
        'REVOKE SELECT ON TABLES FROM dbt_owner';
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA app FROM dbt_owner';
    EXECUTE 'REVOKE ALL ON SCHEMA app FROM dbt_owner';

    EXECUTE 'GRANT ALL ON SCHEMA app TO rails_app';
    EXECUTE 'GRANT USAGE ON SCHEMA analytics TO rails_app';
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE rails_app IN SCHEMA app '
        'GRANT SELECT, UPDATE ON TABLES TO pipeline_writer';

    EXECUTE 'GRANT USAGE ON SCHEMA fd TO rails_app';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA fd TO rails_app';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA fd '
        'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rails_app';
    EXECUTE 'GRANT USAGE ON ALL SEQUENCES IN SCHEMA fd TO rails_app';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA fd GRANT USAGE ON SEQUENCES TO rails_app';

    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'app' AND tablename = 'sync_request') THEN
        EXECUTE 'GRANT SELECT, UPDATE ON app.sync_request TO pipeline_writer';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'fd' AND tablename = 'audit') THEN
        EXECUTE 'REVOKE UPDATE, DELETE ON fd.audit FROM pipeline_writer';
        EXECUTE 'REVOKE UPDATE, DELETE ON fd.audit FROM rails_app';
    END IF;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'single-role deployment: % may not administer pipeline_writer, dbt_owner '
            'and rails_app (%), so every service shares %. write ownership is not enforced '
            'on this server', current_user, SQLERRM, current_user;
END
$$;
