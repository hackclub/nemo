ALTER TABLE fd.login_event ADD COLUMN IF NOT EXISTS ua_read_at timestamptz;

DROP INDEX IF EXISTS fd.login_event_unread_agent_idx;

CREATE INDEX IF NOT EXISTS login_event_unread_agent_idx
    ON fd.login_event (at DESC)
    WHERE ua IS NOT NULL AND ua_read_at IS NULL;
