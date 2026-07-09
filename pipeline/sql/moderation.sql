CREATE TABLE IF NOT EXISTS moderation.member_profile (
    user_id text PRIMARY KEY,
    name text,
    display_name text,
    username text,
    email text,
    claimed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE moderation.member_profile ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
