DROP INDEX IF EXISTS fd.login_event_ip_idx;

ALTER TABLE fd.login_event DROP COLUMN IF EXISTS ip_prefix;

ALTER TABLE fd.login_event
    ADD COLUMN ip_prefix inet
    GENERATED ALWAYS AS (
        network(set_masklen(ip, CASE WHEN family(ip) = 4 THEN 24 ELSE 64 END))
    ) STORED;

CREATE INDEX login_event_ip_idx ON fd.login_event (ip_prefix, at DESC)
    WHERE ip_prefix IS NOT NULL;

TRUNCATE fd.ip_cohort;
