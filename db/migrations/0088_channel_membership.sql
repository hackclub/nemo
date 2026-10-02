ALTER TABLE raw.channel_dim
    ADD COLUMN IF NOT EXISTS is_member boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS membership_seen_at timestamptz,
    ADD COLUMN IF NOT EXISTS join_blocked_at timestamptz,
    ADD COLUMN IF NOT EXISTS join_error text;

CREATE INDEX IF NOT EXISTS channel_dim_joinable_idx
    ON raw.channel_dim (channel_id)
    WHERE archived IS NOT TRUE AND is_member IS FALSE AND join_blocked_at IS NULL;
