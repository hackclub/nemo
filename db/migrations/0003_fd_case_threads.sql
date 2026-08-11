CREATE TABLE fd.case_threads (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id bigint NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    is_primary boolean NOT NULL DEFAULT false,
    added_by text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (case_id, channel_id, thread_ts)
);

CREATE UNIQUE INDEX case_threads_one_primary ON fd.case_threads (case_id)
    WHERE is_primary;

CREATE INDEX case_threads_thread_idx ON fd.case_threads (channel_id, thread_ts);
