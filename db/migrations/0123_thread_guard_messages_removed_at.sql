ALTER TABLE fd.thread_guard_messages
    ADD COLUMN removed_at timestamptz;

CREATE INDEX thread_guard_messages_still_up
    ON fd.thread_guard_messages (guard_id, message_ts)
    WHERE removed_at IS NULL;
