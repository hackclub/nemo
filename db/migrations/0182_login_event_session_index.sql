CREATE INDEX IF NOT EXISTS login_event_session_idx ON fd.login_event (session_id)
    WHERE session_id IS NOT NULL AND action = 'user_login';
