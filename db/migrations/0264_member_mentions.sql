CREATE OR REPLACE FUNCTION fd.member_mentions(target_user_id text, posted_before timestamptz,
                                              row_limit integer)
RETURNS TABLE (channel_id text, ts text, thread_root_ts text, posted_at timestamptz,
               author_id text, author_kind text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH fd_channel AS (
        SELECT DISTINCT btrim(listed.channel_id) AS channel_id
        FROM fd.app_settings s
        CROSS JOIN LATERAL unnest(string_to_array(s.value, ',')) AS listed(channel_id)
        WHERE s.key IN ('nemo.firehouse_channel', 'nemo.reports_channel', 'nemo.log_channel',
                        'nemo.case_react_channels')
          AND btrim(listed.channel_id) <> ''
    )
    SELECT m.channel_id, m.ts, m.thread_root_ts, m.posted_at, m.author_id, m.author_kind
    FROM archive.message m
    WHERE m.channel_id IN (SELECT f.channel_id FROM fd_channel f)
      AND m.mentioned_ids @> ARRAY[target_user_id]
      AND m.deleted_at IS NULL
      AND m.author_id IS DISTINCT FROM target_user_id
      AND (posted_before IS NULL OR m.posted_at < posted_before)
    ORDER BY m.posted_at DESC, m.ts DESC
    LIMIT least(greatest(coalesce(row_limit, 25), 1), 101)
$$;

REVOKE ALL ON FUNCTION fd.member_mentions(text, timestamptz, integer) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT EXECUTE ON FUNCTION fd.member_mentions(text, timestamptz, integer) TO rails_app;
    END IF;
END
$$;
