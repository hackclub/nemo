CREATE TABLE IF NOT EXISTS fd.member_trait (
    user_id    text        NOT NULL,
    kind       text        NOT NULL,
    value      text        NOT NULL,
    first_seen timestamptz,
    last_seen  timestamptz,
    seen       integer     NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, kind, value),
    CONSTRAINT member_trait_kind_known CHECK (kind IN (
        'ip', 'ip_prefix', 'ua_id', 'session_agent', 'ja4',
        'email_domain', 'mailbox', 'local_part',
        'full_name', 'display_name', 'handle_stem', 'inviter'
    )),
    CONSTRAINT member_trait_seen_in_order CHECK (first_seen <= last_seen)
);

CREATE INDEX IF NOT EXISTS member_trait_shared_idx ON fd.member_trait (kind, value);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.member_trait TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.member_trait TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_trait FROM dbt_owner;
    END IF;
END
$$;
