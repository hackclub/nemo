DO $$
DECLARE
    kind char;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        RETURN;
    END IF;

    SELECT relkind INTO kind FROM pg_class WHERE oid = to_regclass('analytics.dim_channel');

    IF kind = 'r' THEN
        EXECUTE 'ALTER TABLE analytics.dim_channel OWNER TO dbt_owner';
    ELSIF kind = 'v' THEN
        EXECUTE 'ALTER VIEW analytics.dim_channel OWNER TO dbt_owner';
    END IF;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'analytics.dim_channel keeps its owner: %', SQLERRM;
END
$$;
