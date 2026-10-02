CREATE SCHEMA IF NOT EXISTS slack;

CREATE TABLE IF NOT EXISTS slack.audit_event (
    id           text        NOT NULL PRIMARY KEY,
    at           timestamptz NOT NULL,
    action       text        NOT NULL,
    actor_kind   text,
    actor_id     text,
    entity_kind  text,
    entity_id    text,
    app_id       text,
    ours         boolean     NOT NULL DEFAULT false,
    context      jsonb,
    payload      jsonb       NOT NULL,
    source_key   text        NOT NULL,
    landed_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_event_at_idx ON slack.audit_event (at DESC, id DESC);
CREATE INDEX IF NOT EXISTS audit_event_action_idx ON slack.audit_event (action, at DESC);
CREATE INDEX IF NOT EXISTS audit_event_actor_idx ON slack.audit_event (actor_id, at DESC)
    WHERE actor_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_event_entity_idx ON slack.audit_event (entity_id, at DESC)
    WHERE entity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_event_theirs_idx ON slack.audit_event (at DESC)
    WHERE NOT ours;

CREATE TABLE IF NOT EXISTS fd.login_event (
    user_id    text        NOT NULL,
    at         timestamptz NOT NULL,
    source     text        NOT NULL,
    action     text        NOT NULL,
    ip         inet,
    ip_prefix  inet,
    ua         text,
    ua_app     text,
    ua_os      text,
    session_id bigint,
    country    text,
    region     text,
    isp        text,
    seen       integer     NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, at, source),
    CONSTRAINT login_event_source_known CHECK (source IN ('audit_logs', 'access_logs'))
);

CREATE INDEX IF NOT EXISTS login_event_who_idx ON fd.login_event (user_id, at DESC);
CREATE INDEX IF NOT EXISTS login_event_ip_idx ON fd.login_event (ip_prefix, at DESC)
    WHERE ip_prefix IS NOT NULL;
CREATE INDEX IF NOT EXISTS login_event_recent_idx ON fd.login_event (at DESC);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT USAGE ON SCHEMA slack TO pipeline_writer;
        GRANT SELECT, INSERT, UPDATE, DELETE ON slack.audit_event TO pipeline_writer;
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.login_event TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT USAGE ON SCHEMA slack TO rails_app;
        GRANT SELECT ON slack.audit_event TO rails_app;
        GRANT SELECT ON fd.login_event TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.login_event FROM dbt_owner;
    END IF;
END
$$;
