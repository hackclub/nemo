CREATE TABLE fd.thread_messages (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    message_ts text NOT NULL,
    author_user_id text NOT NULL,
    posted_at timestamptz NOT NULL,
    body text,
    is_root boolean NOT NULL DEFAULT false,
    deleted_in_slack boolean NOT NULL DEFAULT false,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    source_app text NOT NULL DEFAULT 'fire_engine',
    UNIQUE (channel_id, thread_ts, message_ts),
    CONSTRAINT thread_messages_deleted_has_no_body CHECK (
        NOT deleted_in_slack OR body IS NULL
    )
);

CREATE INDEX thread_messages_thread_idx
    ON fd.thread_messages (channel_id, thread_ts, posted_at);

CREATE UNIQUE INDEX thread_messages_one_root
    ON fd.thread_messages (channel_id, thread_ts)
    WHERE is_root;

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
