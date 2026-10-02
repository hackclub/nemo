CREATE INDEX IF NOT EXISTS login_event_unread_agent_idx
    ON fd.login_event (at DESC)
    WHERE ua IS NOT NULL AND (ua_app IS NULL OR ua_os IS NULL);
