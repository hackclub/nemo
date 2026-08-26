CREATE TABLE raw.member_channel_message (
    user_id text NOT NULL,
    channel_id text NOT NULL,
    messages integer NOT NULL,
    first_ts timestamptz,
    last_ts timestamptz,
    searched_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, channel_id),
    CONSTRAINT member_channel_message_counts CHECK (messages > 0)
);

CREATE INDEX member_channel_message_channel_idx
    ON raw.member_channel_message (channel_id);

CREATE TABLE raw.member_channel_membership (
    user_id text NOT NULL,
    channel_id text NOT NULL,
    seen_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, channel_id)
);

CREATE INDEX member_channel_membership_channel_idx
    ON raw.member_channel_membership (channel_id);

CREATE TABLE raw.member_channel_walk (
    user_id text PRIMARY KEY,
    messages_searched_at timestamptz,
    membership_read_at timestamptz,
    pages integer,
    truncated boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT member_channel_walk_pages CHECK (pages IS NULL OR pages BETWEEN 1 AND 100)
);
