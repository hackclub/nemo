CREATE TABLE fd.thread_messages (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    message_ts text NOT NULL,
    parent_ts text,
    is_root boolean NOT NULL DEFAULT false,
    author_user_id text,
    author_bot_id text,
    subtype text,
    body text,
    file_count integer NOT NULL DEFAULT 0,
    permalink text,
    reply_count integer,
    posted_at timestamptz NOT NULL,
    edited_at timestamptz,
    deleted_at timestamptz,
    purged_at timestamptz,
    purged_by text,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    source_app text NOT NULL DEFAULT 'fire_engine',
    UNIQUE (channel_id, thread_ts, message_ts),
    CONSTRAINT thread_messages_root_has_no_parent CHECK ((parent_ts IS NULL) = is_root),
    CONSTRAINT thread_messages_written_by_somebody CHECK (
        author_user_id IS NOT NULL OR author_bot_id IS NOT NULL OR subtype IS NOT NULL
    ),
    CONSTRAINT thread_messages_reply_count_on_root CHECK (reply_count IS NULL OR is_root),
    CONSTRAINT thread_messages_purged_together CHECK ((purged_at IS NULL) = (purged_by IS NULL)),
    CONSTRAINT thread_messages_purged_has_no_body CHECK (purged_at IS NULL OR body IS NULL)
);

CREATE UNIQUE INDEX thread_messages_one_root
    ON fd.thread_messages (channel_id, thread_ts)
    WHERE is_root;

CREATE INDEX thread_messages_thread_idx
    ON fd.thread_messages (channel_id, thread_ts, posted_at);

CREATE INDEX thread_messages_author_idx
    ON fd.thread_messages (author_user_id, posted_at DESC)
    WHERE author_user_id IS NOT NULL;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        EXECUTE 'REVOKE ALL ON fd.thread_messages FROM dbt_owner';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        EXECUTE 'REVOKE INSERT, UPDATE, DELETE ON fd.thread_messages FROM rails_app';
    END IF;
END
$$;
