CREATE TABLE fd.channel_guard_notice_threads (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guard_id bigint NOT NULL REFERENCES fd.channel_guards(id) ON DELETE CASCADE,
    subject_id text NOT NULL,
    parent_ts text NOT NULL,
    deleted_count integer NOT NULL DEFAULT 0,
    kicked_count integer NOT NULL DEFAULT 0,
    opened_at timestamptz NOT NULL DEFAULT now(),
    last_event_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX channel_guard_notice_threads_latest
    ON fd.channel_guard_notice_threads (guard_id, subject_id, last_event_at DESC);

DROP INDEX IF EXISTS fd.channel_guard_events_still_telling;

ALTER TABLE fd.channel_guard_events
    DROP COLUMN IF EXISTS told_ts,
    DROP COLUMN IF EXISTS told_until;
