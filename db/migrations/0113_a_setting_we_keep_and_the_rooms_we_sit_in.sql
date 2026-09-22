CREATE TABLE fd.app_settings (
    key text PRIMARY KEY,
    value text NOT NULL,
    changed_by text,
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT app_settings_value_present CHECK (btrim(value) <> '')
);

CREATE TABLE fd.channel_joins (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id text NOT NULL,
    verb text NOT NULL,
    why text,
    by_user_id text,
    at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT channel_joins_verb_known
        CHECK (verb IN ('joined', 'rejoined', 'left', 'refused'))
);

CREATE INDEX channel_joins_recent ON fd.channel_joins (at DESC);

CREATE INDEX channel_joins_lately ON fd.channel_joins (channel_id, at DESC);

CREATE INDEX channel_joins_refused ON fd.channel_joins (at DESC)
    WHERE verb = 'refused';
