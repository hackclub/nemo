CREATE INDEX IF NOT EXISTS archive_message_updated_idx
    ON archive.message (updated_at);

CREATE INDEX IF NOT EXISTS archive_message_deleted_idx
    ON archive.message (channel_id, ts) WHERE deleted_at IS NOT NULL;
