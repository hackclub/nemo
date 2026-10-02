CREATE TABLE IF NOT EXISTS raw.member_dim_snapshot (
    user_id text NOT NULL,
    observed_on date NOT NULL,
    record_hash text NOT NULL,
    account_created timestamptz,
    account_created_verified timestamptz,
    claimed_at timestamptz,
    deactivated_at timestamptz,
    is_bot boolean,
    is_admin boolean,
    is_owner boolean,
    is_primary_owner boolean,
    is_restricted boolean,
    is_ultra_restricted boolean,
    is_invited_member boolean,
    is_invited_guest boolean,
    is_deleted boolean,
    invite_pending boolean,
    observed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, observed_on)
);

CREATE TABLE IF NOT EXISTS raw.channel_dim_snapshot (
    channel_id text NOT NULL,
    observed_on date NOT NULL,
    record_hash text NOT NULL,
    name text,
    visibility text,
    archived boolean,
    date_created timestamptz,
    observed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, observed_on)
);
