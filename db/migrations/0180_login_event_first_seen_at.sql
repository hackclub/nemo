ALTER TABLE fd.login_event ADD COLUMN IF NOT EXISTS first_seen_at timestamptz;
