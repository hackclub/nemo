ALTER TABLE fd.intake_conversations
    ADD COLUMN thread_ts text;

UPDATE fd.intake_conversations c
SET thread_ts = (
    SELECT coalesce(m.thread_ts, m.ts)
    FROM fd.intake_messages m
    WHERE m.conversation_id = c.id AND m.direction = 'inbound'
    ORDER BY m.posted_at, m.id
    LIMIT 1
)
WHERE thread_ts IS NULL;

DROP INDEX fd.intake_conversations_one_open;

CREATE UNIQUE INDEX intake_conversations_thread_idx
    ON fd.intake_conversations (channel_id, thread_ts)
    WHERE thread_ts IS NOT NULL;

CREATE UNIQUE INDEX intake_conversations_one_unthreaded
    ON fd.intake_conversations (channel_id)
    WHERE thread_ts IS NULL AND closed_at IS NULL;
