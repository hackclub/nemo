ALTER TABLE app.channel_audience DROP CONSTRAINT IF EXISTS channel_audience_kind;
ALTER TABLE app.channel_audience ADD CONSTRAINT channel_audience_kind
    CHECK (audience IN ('private', 'shared', 'everyone', 'granted', 'public'));

CREATE OR REPLACE FUNCTION app.may_see_channel(who text, channel text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM app.grant g JOIN app.role r ON r.name = g.name
        WHERE g.user_id = who AND g.kind = 'role' AND g.revoked_at IS NULL AND r.everything
    ) OR EXISTS (
        SELECT 1 FROM app.channel_audience a
        WHERE a.channel_id = channel AND a.audience IN ('public', 'everyone')
    ) OR (
        app.holds_capability(who, 'channel.read') AND EXISTS (
            SELECT 1 FROM app.channel_grants cg
            WHERE cg.channel_id = channel AND cg.revoked_at IS NULL
              AND (
                  cg.user_id = who
                  OR cg.role IN (
                      SELECT g.name FROM app.grant g
                      WHERE g.user_id = who AND g.kind = 'role' AND g.revoked_at IS NULL
                  )
              )
        )
    );
$$;
