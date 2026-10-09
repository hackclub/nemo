CREATE TABLE IF NOT EXISTS slack.user_agent (
    id         integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ua         text        NOT NULL,
    first_seen timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS user_agent_text_idx ON slack.user_agent (md5(ua));

CREATE TABLE slack.audit_event_monthly (
    id           uuid        NOT NULL,
    at           timestamptz NOT NULL,
    action       text        NOT NULL,
    category     text,
    actor_kind   text,
    actor_id     text,
    actor_email  text,
    entity_kind  text,
    entity_id    text,
    entity_email text,
    channel_id   text,
    app_id       text,
    ours         boolean     NOT NULL DEFAULT false,
    ip           inet,
    ua_id        integer     REFERENCES slack.user_agent (id),
    session_id   bigint,
    source_key   text,
    payload      jsonb       NOT NULL,
    PRIMARY KEY (id, at),
    CONSTRAINT audit_event_monthly_emails_lower
        CHECK (actor_email = lower(actor_email) AND entity_email = lower(entity_email))
) PARTITION BY RANGE (at);

ALTER TABLE slack.audit_event_monthly ALTER COLUMN payload SET COMPRESSION lz4;

CREATE INDEX audit_event_monthly_recent_idx ON slack.audit_event_monthly (at DESC, id DESC);
CREATE INDEX audit_event_monthly_action_idx ON slack.audit_event_monthly (action, at DESC);
CREATE INDEX audit_event_monthly_category_idx ON slack.audit_event_monthly (category, at DESC);
CREATE INDEX audit_event_monthly_actor_idx ON slack.audit_event_monthly (actor_id, at DESC)
    WHERE actor_id IS NOT NULL;
CREATE INDEX audit_event_monthly_entity_idx ON slack.audit_event_monthly (entity_id, at DESC)
    WHERE entity_id IS NOT NULL;
CREATE INDEX audit_event_monthly_channel_idx ON slack.audit_event_monthly (channel_id, at DESC)
    WHERE channel_id IS NOT NULL;
CREATE INDEX audit_event_monthly_ip_idx ON slack.audit_event_monthly (ip, at DESC)
    WHERE ip IS NOT NULL;
CREATE INDEX audit_event_monthly_actor_email_idx ON slack.audit_event_monthly (actor_email)
    WHERE actor_email IS NOT NULL;
CREATE INDEX audit_event_monthly_entity_email_idx ON slack.audit_event_monthly (entity_email)
    WHERE entity_email IS NOT NULL;
CREATE INDEX audit_event_monthly_session_idx ON slack.audit_event_monthly (session_id)
    WHERE session_id IS NOT NULL;

CREATE TABLE slack.audit_event_monthly_default PARTITION OF slack.audit_event_monthly DEFAULT;

ALTER TABLE slack.audit_event_monthly_default ALTER COLUMN payload SET COMPRESSION lz4;

CREATE OR REPLACE FUNCTION slack.ensure_audit_event_months(first_month date, months_ahead integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    month date := date_trunc('month', first_month)::date;
    last_month date := (date_trunc('month', now()) + make_interval(months => months_ahead))::date;
    named text;
    made integer := 0;
BEGIN
    WHILE month <= last_month LOOP
        named := 'audit_event_' || to_char(month, 'YYYY_MM');
        IF to_regclass('slack.' || named) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE slack.%I PARTITION OF slack.audit_event_monthly '
                'FOR VALUES FROM (%L) TO (%L)',
                named,
                to_char(month, 'YYYY-MM-DD') || ' 00:00:00+00',
                to_char((month + interval '1 month')::date, 'YYYY-MM-DD') || ' 00:00:00+00');
            EXECUTE format('ALTER TABLE slack.%I ALTER COLUMN payload SET COMPRESSION lz4', named);
            made := made + 1;
        END IF;
        month := (month + interval '1 month')::date;
    END LOOP;
    RETURN made;
END
$$;

SELECT slack.ensure_audit_event_months('2025-11-01', 2);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON slack.audit_event_monthly TO pipeline_writer;
        GRANT SELECT, INSERT ON slack.user_agent TO pipeline_writer;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA slack TO pipeline_writer;
        GRANT EXECUTE ON FUNCTION slack.ensure_audit_event_months(date, integer) TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON slack.audit_event_monthly TO rails_app;
        GRANT SELECT ON slack.user_agent TO rails_app;
    END IF;
END
$$;
