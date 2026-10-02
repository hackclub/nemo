CREATE INDEX IF NOT EXISTS access_log_recent_idx ON app.access_log (looked_at DESC, id DESC);
