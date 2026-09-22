CREATE TABLE fd.thread_guard_messages (
    guard_id bigint NOT NULL REFERENCES fd.thread_guards(id) ON DELETE CASCADE,
    message_ts text NOT NULL,
    user_id text NOT NULL,
    channel_id text NOT NULL,
    at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (guard_id, message_ts)
);

CREATE INDEX thread_guard_messages_who ON fd.thread_guard_messages (guard_id, user_id);
