-- nemo answers "how did this do?" only in a channel an admin opened up, so the
-- bot needs to read the list rails keeps

DO $$
BEGIN
    EXECUTE 'GRANT SELECT ON app.channel_message_activity TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        RAISE NOTICE 'channel_message_activity: could not set role grants (%), single-role deployment', SQLERRM;
END
$$;
