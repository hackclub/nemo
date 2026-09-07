CREATE SCHEMA IF NOT EXISTS archive;

CREATE TABLE IF NOT EXISTS archive.envelope (
    channel_id   text        NOT NULL,
    ts           text        NOT NULL,
    revision     integer     NOT NULL,
    payload      jsonb       NOT NULL,
    payload_hash bytea       NOT NULL,
    method       text        NOT NULL,
    fetched_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, ts, revision)
);

CREATE TABLE IF NOT EXISTS archive.message (
    channel_id        text        NOT NULL,
    ts                text        NOT NULL,
    revision          integer     NOT NULL DEFAULT 1,
    posted_at         timestamptz NOT NULL,
    author_id         text,
    author_kind       text        NOT NULL,
    bot_id            text,
    app_id            text,
    parent_user_id    text,
    subtype           text,
    thread_root_ts    text,
    is_reply          boolean     NOT NULL DEFAULT false,
    is_broadcast      boolean     NOT NULL DEFAULT false,
    reply_count       integer,
    reply_users_count integer,
    latest_reply_ts   text,
    text_length       integer,
    has_text          boolean,
    block_count       integer,
    attachment_count  integer,
    file_count        integer,
    mention_count     integer,
    mentioned_ids     text[],
    is_question       boolean,
    is_substantive    boolean,
    has_link          boolean,
    emoji_only        boolean,
    reaction_count    integer,
    reactor_count     integer,
    edited_at         timestamptz,
    edited_by         text,
    deleted_at        timestamptz,
    client_msg_id     text,
    team_id           text,
    settled           boolean     NOT NULL DEFAULT false,
    first_seen_at     timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, ts)
);

CREATE TABLE IF NOT EXISTS archive.observation (
    channel_id  text        NOT NULL,
    ts          text        NOT NULL,
    transport   text        NOT NULL,
    revision    integer     NOT NULL,
    observed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, ts, transport, revision)
);

CREATE INDEX IF NOT EXISTS archive_message_time_idx
    ON archive.message (posted_at);
CREATE INDEX IF NOT EXISTS archive_message_author_time_idx
    ON archive.message (author_id, posted_at) WHERE author_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS archive_message_channel_time_idx
    ON archive.message (channel_id, posted_at);
CREATE INDEX IF NOT EXISTS archive_message_thread_idx
    ON archive.message (channel_id, thread_root_ts) WHERE thread_root_ts IS NOT NULL;
CREATE INDEX IF NOT EXISTS archive_message_unsettled_idx
    ON archive.message (channel_id, ts) WHERE NOT settled;
CREATE INDEX IF NOT EXISTS archive_message_owed_replies_idx
    ON archive.message (channel_id, ts) WHERE reply_count > 0;
