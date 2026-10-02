CREATE INDEX IF NOT EXISTS archive_message_first_seen_idx
    ON archive.message (first_seen_at);

COMMENT ON INDEX archive.archive_message_first_seen_idx IS
    'The engine reads messages held as the mart total plus the rows landed since it was built. Without this the delta seq scans the whole archive.';
