CREATE TABLE fd.blocked_domains (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    domain text NOT NULL,
    match_mode text NOT NULL DEFAULT 'exact',
    effect text NOT NULL DEFAULT 'flag',
    note text,
    active boolean NOT NULL DEFAULT true,
    added_by text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    retired_at timestamptz,
    retired_by text,
    CONSTRAINT blocked_domains_domain_present CHECK (btrim(domain) <> ''),
    CONSTRAINT blocked_domains_domain_has_a_dot CHECK (position('.' IN domain) > 0),
    CONSTRAINT blocked_domains_domain_is_lower CHECK (domain = lower(domain)),
    CONSTRAINT blocked_domains_match_known CHECK (match_mode IN ('exact', 'suffix')),
    CONSTRAINT blocked_domains_effect_known CHECK (effect IN ('flag', 'hold', 'deactivate')),
    CONSTRAINT blocked_domains_retired_together
        CHECK ((retired_at IS NULL) = (retired_by IS NULL)),
    CONSTRAINT blocked_domains_active_is_not_retired
        CHECK (NOT active OR retired_at IS NULL)
);

CREATE UNIQUE INDEX blocked_domains_one_live
    ON fd.blocked_domains (domain, match_mode) WHERE active;

CREATE INDEX blocked_domains_live ON fd.blocked_domains (added_at DESC) WHERE active;

CREATE TABLE fd.join_screen (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id text NOT NULL,
    at timestamptz NOT NULL DEFAULT now(),
    email_domain text,
    domain_id bigint REFERENCES fd.blocked_domains(id) ON DELETE SET NULL,
    matched text,
    effect text,
    outcome text NOT NULL,
    guard_id bigint REFERENCES fd.member_guards(id) ON DELETE SET NULL,
    detail text,
    CONSTRAINT join_screen_outcome_known
        CHECK (outcome IN ('allowed', 'flagged', 'held', 'deactivated', 'failed', 'no_email'))
);

CREATE UNIQUE INDEX join_screen_one_per_member ON fd.join_screen (user_id);
CREATE INDEX join_screen_recent ON fd.join_screen (at DESC);
CREATE INDEX join_screen_caught ON fd.join_screen (at DESC) WHERE outcome <> 'allowed';
CREATE INDEX join_screen_by_domain ON fd.join_screen (email_domain, at DESC)
    WHERE email_domain IS NOT NULL;

CREATE OR REPLACE FUNCTION fd.blocked_domain_changed() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_blocked_domain', '');
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER blocked_domains_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.blocked_domains
    FOR EACH STATEMENT EXECUTE FUNCTION fd.blocked_domain_changed();

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE ON fd.blocked_domains TO pipeline_writer;
        GRANT SELECT, INSERT, UPDATE ON fd.join_screen TO pipeline_writer;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA fd TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT, INSERT, UPDATE ON fd.blocked_domains TO rails_app;
        GRANT SELECT ON fd.join_screen TO rails_app;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA fd TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.join_screen FROM dbt_owner;
    END IF;
END
$$;
