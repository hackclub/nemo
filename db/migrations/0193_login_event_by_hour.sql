LOCK TABLE fd.login_event IN SHARE MODE;

SET LOCAL work_mem = '256MB';
SET LOCAL maintenance_work_mem = '512MB';

ALTER TABLE slack.user_agent ADD COLUMN app text;
ALTER TABLE slack.user_agent ADD COLUMN os text;
ALTER TABLE slack.user_agent ADD COLUMN read_at timestamptz;

CREATE INDEX user_agent_unread_idx ON slack.user_agent (id) WHERE read_at IS NULL;

INSERT INTO slack.user_agent (ua)
SELECT DISTINCT ua FROM fd.login_event WHERE ua IS NOT NULL AND ua <> ''
ON CONFLICT (md5(ua)) DO NOTHING;

UPDATE slack.user_agent u
SET app = read.ua_app, os = read.ua_os, read_at = read.ua_read_at
FROM (
    SELECT DISTINCT ON (md5(ua)) ua, ua_app, ua_os, ua_read_at
    FROM fd.login_event
    WHERE ua IS NOT NULL AND ua <> '' AND ua_read_at IS NOT NULL
    ORDER BY md5(ua), ua_read_at DESC
) read
WHERE md5(u.ua) = md5(read.ua);

CREATE TABLE fd.login_session (
    session_id bigint      NOT NULL,
    user_id    text        NOT NULL,
    at         timestamptz NOT NULL,
    PRIMARY KEY (session_id, user_id)
);

INSERT INTO fd.login_session (session_id, user_id, at)
SELECT session_id, user_id, min(at)
FROM fd.login_event
WHERE session_id IS NOT NULL AND action = 'user_login'
GROUP BY 1, 2;

CREATE TABLE fd.login_event_hourly (
    user_id       text        NOT NULL,
    source        text        NOT NULL,
    hour          timestamptz NOT NULL,
    ip            inet,
    ip_prefix     inet GENERATED ALWAYS AS (
        network(set_masklen(ip, CASE WHEN family(ip) = 4 THEN 24 ELSE 64 END))
    ) STORED,
    ua_id         integer     REFERENCES slack.user_agent (id),
    first_at      timestamptz NOT NULL,
    last_at       timestamptz NOT NULL,
    hits          integer     NOT NULL DEFAULT 1,
    logins        integer     NOT NULL DEFAULT 0,
    failures      integer     NOT NULL DEFAULT 0,
    anomalies     integer     NOT NULL DEFAULT 0,
    seen          integer     NOT NULL DEFAULT 1,
    first_seen_at timestamptz,
    country       text,
    region        text,
    isp           text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT login_event_hourly_source_known CHECK (source IN ('audit_logs', 'access_logs')),
    CONSTRAINT login_event_hourly_inside_its_hour
        CHECK (first_at >= hour AND last_at < hour + interval '1 hour' AND first_at <= last_at)
);

INSERT INTO fd.login_event_hourly
    (user_id, source, hour, ip, ua_id, first_at, last_at, hits, logins, failures, anomalies,
     seen, first_seen_at, country, region, isp, updated_at)
SELECT e.user_id, e.source, date_trunc('hour', e.at, 'UTC'), e.ip, u.id,
       min(e.at), max(e.at), count(*),
       count(*) FILTER (WHERE e.action = 'user_login'),
       count(*) FILTER (WHERE e.action = 'user_login_failed'),
       count(*) FILTER (WHERE e.action = 'anomaly'),
       CASE WHEN e.source = 'access_logs' THEN max(e.seen) ELSE sum(e.seen) END,
       min(e.first_seen_at), max(e.country), max(e.region), max(e.isp), max(e.updated_at)
FROM fd.login_event e
LEFT JOIN slack.user_agent u ON md5(u.ua) = md5(e.ua) AND e.ua <> ''
GROUP BY e.user_id, e.source, date_trunc('hour', e.at, 'UTC'), e.ip, u.id;

CREATE UNIQUE INDEX login_event_hourly_key_idx ON fd.login_event_hourly
    (user_id, source, hour, ip, ua_id) NULLS NOT DISTINCT;
CREATE INDEX login_event_hourly_who_idx ON fd.login_event_hourly (user_id, last_at DESC);
CREATE INDEX login_event_hourly_ip_idx ON fd.login_event_hourly (ip) WHERE ip IS NOT NULL;
CREATE INDEX login_event_hourly_prefix_idx ON fd.login_event_hourly (ip_prefix)
    WHERE ip_prefix IS NOT NULL;
CREATE INDEX login_event_hourly_source_idx ON fd.login_event_hourly (source, last_at DESC);

DROP TABLE fd.login_event;

ALTER TABLE fd.login_event_hourly RENAME TO login_event;
ALTER TABLE fd.login_event RENAME CONSTRAINT login_event_hourly_source_known TO login_event_source_known;
ALTER TABLE fd.login_event RENAME CONSTRAINT login_event_hourly_inside_its_hour TO login_event_inside_its_hour;
ALTER TABLE fd.login_event RENAME CONSTRAINT login_event_hourly_ua_id_fkey TO login_event_ua_id_fkey;
ALTER INDEX fd.login_event_hourly_key_idx RENAME TO login_event_key_idx;
ALTER INDEX fd.login_event_hourly_who_idx RENAME TO login_event_who_idx;
ALTER INDEX fd.login_event_hourly_ip_idx RENAME TO login_event_ip_idx;
ALTER INDEX fd.login_event_hourly_prefix_idx RENAME TO login_event_prefix_idx;
ALTER INDEX fd.login_event_hourly_source_idx RENAME TO login_event_source_idx;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.login_event TO pipeline_writer;
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.login_session TO pipeline_writer;
        GRANT UPDATE ON slack.user_agent TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.login_event TO rails_app;
        GRANT SELECT ON fd.login_session TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.login_event FROM dbt_owner;
        REVOKE ALL ON fd.login_session FROM dbt_owner;
    END IF;
END
$$;
