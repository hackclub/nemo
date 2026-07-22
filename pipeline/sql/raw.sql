CREATE TABLE IF NOT EXISTS raw.member_dim (
    user_id text PRIMARY KEY,
    account_type text,
    is_guest boolean,
    account_created timestamptz,
    claimed_at timestamptz,
    deactivated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

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
    creator_id text,
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
