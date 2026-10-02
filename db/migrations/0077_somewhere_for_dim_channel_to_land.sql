DO $$
BEGIN
    IF to_regclass('analytics.dim_channel') IS NULL THEN
        CREATE TABLE analytics.dim_channel (
            channel_id text PRIMARY KEY,
            archived boolean NOT NULL DEFAULT true
        );
    END IF;
END
$$;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT ON analytics.dim_channel TO rails_app';
    EXECUTE 'GRANT SELECT ON analytics.dim_channel TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN NULL;
END
$$;
