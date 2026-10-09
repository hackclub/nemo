CREATE INDEX IF NOT EXISTS audit_view_recent_idx ON slack.audit_view (at DESC, id DESC);
