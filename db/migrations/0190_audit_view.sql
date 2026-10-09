CREATE OR REPLACE FUNCTION slack.ensure_months(parent regclass, prefix text, first_month date,
                                                months_ahead integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    month date := date_trunc('month', first_month)::date;
    last_month date := (date_trunc('month', now()) + make_interval(months => months_ahead))::date;
    compressed boolean := EXISTS (SELECT 1 FROM pg_attribute
                                  WHERE attrelid = parent AND attname = 'payload' AND NOT attisdropped);
    named text;
    made integer := 0;
BEGIN
    WHILE month <= last_month LOOP
        named := prefix || '_' || to_char(month, 'YYYY_MM');
        IF to_regclass('slack.' || named) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE slack.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                named, parent,
                to_char(month, 'YYYY-MM-DD') || ' 00:00:00+00',
                to_char((month + interval '1 month')::date, 'YYYY-MM-DD') || ' 00:00:00+00');
            IF compressed THEN
                EXECUTE format('ALTER TABLE slack.%I ALTER COLUMN payload SET COMPRESSION lz4', named);
            END IF;
            made := made + 1;
        END IF;
        month := (month + interval '1 month')::date;
    END LOOP;
    RETURN made;
END
$$;

CREATE OR REPLACE FUNCTION slack.ensure_audit_event_months(first_month date, months_ahead integer)
RETURNS integer
LANGUAGE sql
AS $$
    SELECT slack.ensure_months('slack.audit_event_monthly', 'audit_event', first_month, months_ahead)
$$;

CREATE TABLE slack.audit_view_action (
    code   smallint PRIMARY KEY,
    action text     NOT NULL UNIQUE
);

INSERT INTO slack.audit_view_action (code, action) VALUES
    (1, 'public_channel_preview'),
    (2, 'list_cell_updated'),
    (3, 'file_downloaded'),
    (4, 'canvas_opened');

CREATE TABLE slack.audit_view (
    id         uuid        NOT NULL,
    at         timestamptz NOT NULL,
    action     smallint    NOT NULL REFERENCES slack.audit_view_action (code),
    actor_id   text,
    object_id  text,
    ip         inet,
    ua_id      integer     REFERENCES slack.user_agent (id),
    session_id bigint,
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);

CREATE INDEX audit_view_action_idx ON slack.audit_view (action, at DESC, id DESC);
CREATE INDEX audit_view_actor_idx ON slack.audit_view (actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX audit_view_object_idx ON slack.audit_view (object_id) WHERE object_id IS NOT NULL;
CREATE INDEX audit_view_ip_idx ON slack.audit_view (ip) WHERE ip IS NOT NULL;

CREATE TABLE slack.audit_view_default PARTITION OF slack.audit_view DEFAULT;

SELECT slack.ensure_months('slack.audit_view', 'audit_view', '2025-11-01', 2);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON slack.audit_view TO pipeline_writer;
        GRANT SELECT ON slack.audit_view_action TO pipeline_writer;
        GRANT EXECUTE ON FUNCTION slack.ensure_months(regclass, text, date, integer) TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON slack.audit_view TO rails_app;
        GRANT SELECT ON slack.audit_view_action TO rails_app;
    END IF;
END
$$;
