ALTER TABLE api.token ADD COLUMN expires_at timestamptz;

CREATE INDEX token_expiry_idx ON api.token (expires_at)
    WHERE revoked_at IS NULL AND expires_at IS NOT NULL;
