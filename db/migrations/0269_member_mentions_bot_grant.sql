DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT EXECUTE ON FUNCTION fd.member_mentions(text, timestamptz, integer) TO pipeline_writer;
    END IF;
END
$$;
