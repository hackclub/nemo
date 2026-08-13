CREATE TABLE fd.decision_threads (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decision_id bigint NOT NULL REFERENCES fd.decisions(id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    why text,
    added_by text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (decision_id, channel_id, thread_ts),
    CONSTRAINT decision_threads_why_present CHECK (why IS NULL OR btrim(why) <> '')
);

CREATE INDEX decision_threads_decision_idx ON fd.decision_threads (decision_id, added_at);

CREATE INDEX decision_threads_thread_idx ON fd.decision_threads (channel_id, thread_ts);
