CREATE TABLE IF NOT EXISTS raw.member_dim (
    user_id text PRIMARY KEY,
    account_created timestamptz,
    claimed_at timestamptz,
    claimed_at_source text,
    deactivated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS claimed_at_source text;

CREATE TABLE IF NOT EXISTS raw.member_activity_snapshot (
    user_id text NOT NULL,
    window_start date NOT NULL,
    window_end date NOT NULL,
    source text NOT NULL,
    days_active integer,
    days_active_desktop integer,
    days_active_android integer,
    days_active_ios integer,
    days_slack_connect integer,
    messages_posted integer,
    channel_messages_posted integer,
    reactions_added integer,
    files_uploaded integer,
    huddles integer,
    searches integer,
    channels_joined integer,
    last_active_at timestamptz,
    last_active_desktop_at timestamptz,
    last_active_android_at timestamptz,
    last_active_ios_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, window_start, window_end, source)
);

CREATE TABLE IF NOT EXISTS raw.channel_dim (
    channel_id text PRIMARY KEY,
    name text,
    visibility text,
    archived boolean,
    date_created timestamptz,
    last_active_at timestamptz,
    total_members integer,
    full_members integer,
    guests integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.channel_activity_snapshot (
    channel_id text NOT NULL,
    window_start date NOT NULL,
    window_end date NOT NULL,
    source text NOT NULL,
    messages_posted integer,
    messages_posted_by_members integer,
    members_who_posted integer,
    change_in_members_who_posted integer,
    members_who_viewed integer,
    reactions_added integer,
    members_who_reacted integer,
    huddles_initiated integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, window_start, window_end, source)
);

ALTER TABLE raw.member_activity_snapshot ADD COLUMN IF NOT EXISTS days_active_apps integer;
ALTER TABLE raw.member_activity_snapshot ADD COLUMN IF NOT EXISTS days_active_workflows integer;

CREATE INDEX IF NOT EXISTS member_activity_snapshot_daily_idx
    ON raw.member_activity_snapshot (window_start)
    WHERE window_start = window_end;

CREATE INDEX IF NOT EXISTS member_activity_snapshot_visits_idx
    ON raw.member_activity_snapshot (window_start, user_id)
    WHERE window_start = window_end AND coalesce(days_active, 0) > 0;

ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_bot boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_admin boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_owner boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_primary_owner boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_restricted boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_ultra_restricted boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS account_created_verified timestamptz;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_invited_member boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_invited_guest boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS is_deleted boolean;
ALTER TABLE raw.member_dim ADD COLUMN IF NOT EXISTS invite_pending boolean;
ALTER TABLE raw.channel_dim ADD COLUMN IF NOT EXISTS name_unavailable boolean;
ALTER TABLE raw.member_dim DROP COLUMN IF EXISTS is_guest;
ALTER TABLE raw.member_dim DROP COLUMN IF EXISTS account_type;
ALTER TABLE raw.member_dim DROP COLUMN IF EXISTS claimed_no_date;
ALTER TABLE raw.channel_dim DROP COLUMN IF EXISTS creator_id;

CREATE TABLE IF NOT EXISTS raw.analytics_day (
    source text NOT NULL,
    ds date NOT NULL,
    loaded boolean NOT NULL DEFAULT false,
    rows_in integer,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, ds)
);

INSERT INTO raw.analytics_day (source, ds, loaded, rows_in)
SELECT 'member_day', window_start, true, count(*)
FROM raw.member_activity_snapshot
WHERE window_start = window_end
GROUP BY window_start
ON CONFLICT (source, ds) DO NOTHING;

INSERT INTO raw.analytics_day (source, ds, loaded, rows_in)
SELECT 'channel_day', window_start, true, count(*)
FROM raw.channel_activity_snapshot
WHERE window_start = window_end
GROUP BY window_start
ON CONFLICT (source, ds) DO NOTHING;

ALTER TABLE raw.analytics_day ADD COLUMN IF NOT EXISTS unavailable boolean;
ALTER TABLE raw.analytics_day ADD COLUMN IF NOT EXISTS reason text;

CREATE TABLE IF NOT EXISTS raw.sync_cursor (
    source text NOT NULL,
    channel_id text NOT NULL DEFAULT '',
    cursor text,
    status text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, channel_id)
);

CREATE TABLE IF NOT EXISTS raw.ingest_run (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source text NOT NULL,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running',
    rows_in integer,
    rows_rejected integer,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE raw.ingest_run ADD COLUMN IF NOT EXISTS total_expected integer;
ALTER TABLE raw.ingest_run ADD COLUMN IF NOT EXISTS parent_run_id bigint;
ALTER TABLE raw.ingest_run ADD COLUMN IF NOT EXISTS step_index smallint;
ALTER TABLE raw.ingest_run ADD COLUMN IF NOT EXISTS step_total smallint;

CREATE INDEX IF NOT EXISTS ingest_run_parent_idx ON raw.ingest_run (parent_run_id, step_index);

CREATE TABLE IF NOT EXISTS raw.ingest_step_output (
    parent_run_id bigint NOT NULL,
    step_index smallint NOT NULL,
    source text,
    output text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (parent_run_id, step_index)
);

CREATE TABLE IF NOT EXISTS raw.dead_letter (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source text NOT NULL,
    payload jsonb NOT NULL,
    reason text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.slack_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.team_stats_snapshot (
    ds date PRIMARY KEY,
    source text NOT NULL,
    total_members_count integer,
    total_claimed_count integer,
    full_members_count integer,
    guests_count integer,
    claimed_full_members_count integer,
    claimed_guests_count integer,
    total_full_members_count integer,
    total_guests_count integer,
    active_users_1d integer,
    active_users_7d integer,
    active_users_28d integer,
    writers_count_1d integer,
    writers_count_7d integer,
    writers_count_28d integer,
    readers_count_1d integer,
    readers_count_7d integer,
    messages_count_1d integer,
    messages_channels_count_from_apps_1d integer,
    chats_count_1d integer,
    chats_channels_count_1d integer,
    chats_groups_count_1d integer,
    chats_dms_count_1d integer,
    chats_shared_channels_count_1d integer,
    cursor_marks_channels_count_1d integer,
    cursor_marks_groups_count_1d integer,
    cursor_marks_dms_count_1d integer,
    cursor_marks_shared_channels_count_1d integer,
    files_count_1d integer,
    files_size bigint,
    channels_count integer,
    users_channels_count integer,
    pulled_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.top_posters_snapshot (
    window_start date NOT NULL,
    window_end date NOT NULL,
    user_id text NOT NULL,
    display_name text,
    messages_posted integer,
    pulled_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (window_start, user_id)
);

CREATE TABLE IF NOT EXISTS raw.message_activity_snapshot (
    channel_id text NOT NULL,
    message_ts text NOT NULL,
    source text NOT NULL,
    unique_user_views_count integer,
    unique_user_reactions_count integer,
    unique_user_shares_count integer,
    unique_user_clicks_count integer,
    views_client jsonb,
    stats_by_department jsonb,
    stats_by_org jsonb,
    pulled_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, message_ts, source)
);

CREATE TABLE IF NOT EXISTS raw.member_message_history (
    user_id text PRIMARY KEY,
    total_messages integer NOT NULL,
    first_post_ts timestamptz,
    first_post_channel text,
    searched_at timestamptz NOT NULL DEFAULT now(),
    counted_through date
);

ALTER TABLE raw.member_message_history ADD COLUMN IF NOT EXISTS counted_through date;

UPDATE raw.member_message_history
SET counted_through = searched_at::date
WHERE counted_through IS NULL;

CREATE TABLE IF NOT EXISTS raw.member_first_reply (
    user_id text PRIMARY KEY,
    replier_id text,
    reply_ts timestamptz,
    latency_seconds integer,
    unreadable boolean,
    reason text,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    bot_replier_id text,
    bot_reply_ts timestamptz,
    bot_latency_seconds integer,
    walk_version smallint NOT NULL DEFAULT 1
);

ALTER TABLE raw.member_first_reply ADD COLUMN IF NOT EXISTS bot_replier_id text;
ALTER TABLE raw.member_first_reply ADD COLUMN IF NOT EXISTS bot_reply_ts timestamptz;
ALTER TABLE raw.member_first_reply ADD COLUMN IF NOT EXISTS bot_latency_seconds integer;
ALTER TABLE raw.member_first_reply ADD COLUMN IF NOT EXISTS walk_version smallint NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS raw.deployment (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    mode text NOT NULL CHECK (mode IN ('live', 'seeded')),
    seeded_at timestamptz,
    seed_profile text,
    seed_scale text,
    seed_rng bigint,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO raw.deployment (id, mode) VALUES (true, 'live') ON CONFLICT (id) DO NOTHING;
