CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE fd.member (
    user_id             text PRIMARY KEY,
    handle              text,
    display_name        text,
    title               text,
    pronouns            text,
    avatar_url          text,
    avatar_hash         text,
    tz                  text,
    tz_offset           integer,
    enterprise_id       text,
    team_ids            text[],
    is_bot              boolean NOT NULL DEFAULT false,
    is_deleted          boolean NOT NULL DEFAULT false,
    is_admin            boolean NOT NULL DEFAULT false,
    is_owner            boolean NOT NULL DEFAULT false,
    is_restricted       boolean NOT NULL DEFAULT false,
    is_ultra_restricted boolean NOT NULL DEFAULT false,
    profile_updated_at  timestamptz,
    first_seen_at       timestamptz NOT NULL DEFAULT now(),
    synced_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX member_display_name_idx ON fd.member
    USING gin (lower(display_name) gin_trgm_ops);

CREATE INDEX member_handle_idx ON fd.member
    USING gin (lower(handle) gin_trgm_ops);

CREATE INDEX member_live_idx ON fd.member (display_name)
    WHERE NOT is_deleted AND NOT is_bot;

CREATE TABLE fd.member_identity (
    user_id     text PRIMARY KEY REFERENCES fd.member(user_id) ON DELETE CASCADE,
    real_name   text,
    first_name  text,
    last_name   text,
    email       text,
    purged_at   timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX member_identity_email_idx ON fd.member_identity (lower(email))
    WHERE email IS NOT NULL;

DO $$
DECLARE
    role_name text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        EXECUTE 'REVOKE ALL ON fd.member FROM dbt_owner';
        EXECUTE 'REVOKE ALL ON fd.member_identity FROM dbt_owner';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        EXECUTE 'REVOKE INSERT, UPDATE, DELETE ON fd.member FROM rails_app';
        EXECUTE 'REVOKE INSERT, UPDATE, DELETE ON fd.member_identity FROM rails_app';
    END IF;
END
$$;
