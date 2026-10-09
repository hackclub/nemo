CREATE TABLE IF NOT EXISTS fd.member_touch (
    user_id    text        PRIMARY KEY,
    touched_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS member_touch_oldest_idx ON fd.member_touch (touched_at);

CREATE TABLE IF NOT EXISTS fd.link_signal_stat (
    signal      text        PRIMARY KEY,
    whole       numeric     NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS fd.shared_ip (
    ip inet PRIMARY KEY
);

CREATE INDEX IF NOT EXISTS user_agent_app_os_idx ON slack.user_agent (app, os)
    WHERE app IS NOT NULL AND os IS NOT NULL;

CREATE OR REPLACE FUNCTION fd.touch_member(who text)
RETURNS void
LANGUAGE sql
AS $$
    INSERT INTO fd.member_touch AS held (user_id, touched_at)
    SELECT who, now() WHERE who IS NOT NULL
    ON CONFLICT (user_id) DO UPDATE SET touched_at = EXCLUDED.touched_at
    WHERE held.touched_at IS DISTINCT FROM EXCLUDED.touched_at
$$;

CREATE OR REPLACE FUNCTION fd.trait_touches_member()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM fd.touch_member(OLD.user_id);
    ELSE
        PERFORM fd.touch_member(NEW.user_id);
    END IF;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION fd.join_touches_member()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fd.touch_member(NEW.user_id);
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION fd.ban_touches_member()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fd.touch_member(NEW.entity_id);
    RETURN NULL;
END
$$;

CREATE TRIGGER member_trait_touches
    AFTER INSERT OR UPDATE OR DELETE ON fd.member_trait
    FOR EACH ROW EXECUTE FUNCTION fd.trait_touches_member();

CREATE TRIGGER member_join_touches
    AFTER INSERT OR UPDATE OF joined_at ON fd.member_joins
    FOR EACH ROW EXECUTE FUNCTION fd.join_touches_member();

CREATE TRIGGER audit_event_ban_touches
    AFTER INSERT ON slack.audit_event
    FOR EACH ROW
    WHEN (NEW.action IN ('user_deactivated', 'user_reactivated'))
    EXECUTE FUNCTION fd.ban_touches_member();

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.member_touch TO pipeline_writer;
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.link_signal_stat TO pipeline_writer;
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.shared_ip TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_touch, fd.link_signal_stat, fd.shared_ip FROM dbt_owner;
    END IF;
END
$$;
