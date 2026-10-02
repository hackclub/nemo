CREATE TABLE IF NOT EXISTS app.prometheus_appointment (
    user_id text NOT NULL,
    channel_id text NOT NULL,
    role text NOT NULL,
    seen_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, channel_id),
    CONSTRAINT prometheus_appointment_role_known
        CHECK (role IN ('manager', 'moderator'))
);

CREATE INDEX IF NOT EXISTS prometheus_appointment_by_channel
    ON app.prometheus_appointment (channel_id);

CREATE OR REPLACE VIEW app.effective_role AS
SELECT g.user_id, g.name AS role
FROM app.grant g
WHERE g.kind = 'role' AND g.revoked_at IS NULL
UNION
SELECT p.user_id, 'promethean'::text
FROM app.prometheus_appointment p
WHERE p.role = 'manager';

CREATE OR REPLACE FUNCTION app.may_see_channel(who text, channel text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM app.effective_role e JOIN app.role r ON r.name = e.role
        WHERE e.user_id = who AND r.everything
    ) OR app.holds_capability(who, 'channel.all')
    OR EXISTS (
        SELECT 1 FROM app.channel_audience a
        WHERE a.channel_id = channel AND a.audience IN ('public', 'everyone')
    ) OR EXISTS (
        SELECT 1 FROM app.prometheus_appointment p
        WHERE p.user_id = who AND p.channel_id = channel AND p.role = 'manager'
    ) OR (
        app.holds_capability(who, 'channel.read') AND EXISTS (
            SELECT 1 FROM app.channel_grants cg
            WHERE cg.channel_id = channel AND cg.revoked_at IS NULL
              AND (
                  cg.user_id = who
                  OR cg.role IN (SELECT e.role FROM app.effective_role e WHERE e.user_id = who)
              )
        )
    );
$$;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON app.prometheus_appointment TO rails_app';
    EXECUTE 'GRANT SELECT ON app.prometheus_appointment TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        RAISE NOTICE 'prometheus_appointment: could not set role grants (%), single-role deployment', SQLERRM;
END
$$;
