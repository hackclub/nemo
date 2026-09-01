CREATE TABLE IF NOT EXISTS raw.message (
    channel_id text NOT NULL,
    ts text NOT NULL,
    source text NOT NULL,
    author_id text,
    author_kind text NOT NULL DEFAULT 'unknown',
    subtype text,
    thread_root_ts text,
    is_reply boolean NOT NULL DEFAULT false,
    posted_at timestamptz NOT NULL,
    edited_at timestamptz,
    edited_by text,
    reply_count integer,
    reply_users_count integer,
    latest_reply_ts text,
    reaction_count integer NOT NULL DEFAULT 0,
    reactor_count integer NOT NULL DEFAULT 0,
    file_count integer NOT NULL DEFAULT 0,
    text_length integer,
    mention_count integer NOT NULL DEFAULT 0,
    is_question boolean,
    is_substantive boolean,
    has_link boolean,
    emoji_only boolean,
    observed_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, ts)
);

CREATE INDEX IF NOT EXISTS message_author_idx ON raw.message (author_id, posted_at);
CREATE INDEX IF NOT EXISTS message_channel_posted_idx ON raw.message (channel_id, posted_at DESC);
CREATE INDEX IF NOT EXISTS message_thread_idx ON raw.message (channel_id, thread_root_ts)
    WHERE thread_root_ts IS NOT NULL;

CREATE TABLE IF NOT EXISTS raw.message_observation (
    channel_id text NOT NULL,
    ts text NOT NULL,
    transport text NOT NULL,
    observed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, ts, transport)
);

CREATE TABLE IF NOT EXISTS raw.thread (
    channel_id text NOT NULL,
    root_ts text NOT NULL,
    reply_count integer NOT NULL DEFAULT 0,
    reply_users_count integer NOT NULL DEFAULT 0,
    latest_reply_ts text,
    replies_fetched integer NOT NULL DEFAULT 0,
    fetched_through_ts text,
    fetched_at timestamptz,
    seen_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, root_ts)
);

CREATE INDEX IF NOT EXISTS thread_incomplete_idx ON raw.thread (channel_id)
    WHERE replies_fetched < reply_count;

CREATE TABLE IF NOT EXISTS raw.channel_walk (
    channel_id text NOT NULL PRIMARY KEY,
    oldest_ts text,
    newest_ts text,
    messages_seen bigint NOT NULL DEFAULT 0,
    history_complete boolean NOT NULL DEFAULT false,
    last_walked_at timestamptz,
    last_error text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.event_delivery (
    event_id text NOT NULL PRIMARY KEY,
    event_type text NOT NULL,
    channel_id text,
    ts text,
    event_ts text,
    received_at timestamptz NOT NULL DEFAULT now(),
    envelope jsonb NOT NULL
);

CREATE INDEX IF NOT EXISTS event_delivery_received_idx ON raw.event_delivery (received_at DESC);
CREATE INDEX IF NOT EXISTS event_delivery_target_idx ON raw.event_delivery (channel_id, ts);

ALTER TABLE raw.channel_dim
    ADD COLUMN IF NOT EXISTS thread_parents integer,
    ADD COLUMN IF NOT EXISTS thread_replies integer,
    ADD COLUMN IF NOT EXISTS threads_counted_at timestamptz;
