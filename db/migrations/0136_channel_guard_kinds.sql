ALTER TABLE fd.channel_guards DROP CONSTRAINT channel_guards_kind_known;

ALTER TABLE fd.channel_guards
    ADD CONSTRAINT channel_guards_kind_known
    CHECK (kind IN ('bot_allowlist', 'readonly', 'slowmode', 'account_age'));

CREATE TABLE fd.slowmode_clock (
    channel_id text NOT NULL,
    thread_ts text NOT NULL DEFAULT '',
    user_id text NOT NULL,
    said_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, thread_ts, user_id)
);

CREATE INDEX slowmode_clock_stale ON fd.slowmode_clock (said_at);
