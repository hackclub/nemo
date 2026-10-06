CREATE INDEX IF NOT EXISTS archive_message_unconfirmed_idx
    ON archive.message (channel_id) WHERE revision = 0;
