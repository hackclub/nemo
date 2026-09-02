CREATE OR REPLACE FUNCTION app.may_see_channel(who text, channel text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM analytics.dim_channel d
        WHERE d.channel_id = channel AND NOT d.archived
    ) AND (
        EXISTS (
            SELECT 1 FROM app.effective_role e JOIN app.role r ON r.name = e.role
            WHERE e.user_id = who AND r.everything
        ) OR app.holds_capability(who, 'channel.all')
        OR EXISTS (
            SELECT 1 FROM app.channel_audience a
            WHERE a.channel_id = channel AND a.audience IN ('public', 'everyone')
        ) OR (
            app.holds_capability(who, 'channel.read') AND EXISTS (
                SELECT 1 FROM app.channel_grants cg
                WHERE cg.channel_id = channel AND cg.revoked_at IS NULL
                  AND (
                      cg.user_id = who
                      OR cg.role IN (SELECT e.role FROM app.effective_role e WHERE e.user_id = who)
                  )
            )
        )
    );
$$;
