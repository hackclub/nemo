DROP INDEX IF EXISTS raw.channel_dim_joinable_idx;

ALTER TABLE raw.channel_dim
    DROP COLUMN IF EXISTS is_member,
    DROP COLUMN IF EXISTS membership_seen_at,
    DROP COLUMN IF EXISTS join_blocked_at,
    DROP COLUMN IF EXISTS join_error;

DROP TABLE IF EXISTS raw.event_delivery;

ALTER TABLE fd.intake_outbox
    ADD COLUMN IF NOT EXISTS files jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS asked_in_channel text,
    ADD COLUMN IF NOT EXISTS asked_at_ts text;

COMMENT ON TABLE fd.intake_outbox IS
    'Everything the Fire Department sends a reporter. Nemo queues it, shroud delivers it, so neither container needs the other and a message written while the other is down simply waits.';

ALTER TABLE fd.cases
    ADD COLUMN IF NOT EXISTS woke_at timestamptz,
    ADD COLUMN IF NOT EXISTS woke_from text,
    ADD COLUMN IF NOT EXISTS woke_told_at timestamptz;

CREATE INDEX IF NOT EXISTS cases_woke_untold_idx ON fd.cases (woke_at)
    WHERE woke_at IS NOT NULL AND woke_told_at IS NULL;
