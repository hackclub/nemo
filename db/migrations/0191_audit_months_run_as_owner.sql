CREATE OR REPLACE FUNCTION slack.ensure_months(parent regclass, prefix text, first_month date,
                                                months_ahead integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = slack, pg_temp
AS $$
DECLARE
    month date := date_trunc('month', first_month)::date;
    last_month date := (date_trunc('month', now()) + make_interval(months => months_ahead))::date;
    compressed boolean := EXISTS (SELECT 1 FROM pg_attribute
                                  WHERE attrelid = parent AND attname = 'payload' AND NOT attisdropped);
    named text;
    made integer := 0;
BEGIN
    IF parent NOT IN ('slack.audit_event_monthly'::regclass, 'slack.audit_view'::regclass) THEN
        RAISE EXCEPTION 'ensure_months only creates months of the audit tables, not %', parent;
    END IF;
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

REVOKE ALL ON FUNCTION slack.ensure_months(regclass, text, date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION slack.ensure_audit_event_months(date, integer) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT EXECUTE ON FUNCTION slack.ensure_months(regclass, text, date, integer) TO pipeline_writer;
        GRANT EXECUTE ON FUNCTION slack.ensure_audit_event_months(date, integer) TO pipeline_writer;
    END IF;
END
$$;
