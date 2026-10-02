CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE api.channel_manager (
    channel_id  text NOT NULL,
    user_id     text NOT NULL,
    assigned_at timestamptz,
    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX channel_manager_user_idx ON api.channel_manager (user_id);

CREATE TABLE api.channel_sweep (
    channel_id text PRIMARY KEY,
    synced_at  timestamptz NOT NULL DEFAULT now(),
    managers   integer NOT NULL DEFAULT 0
);

CREATE TABLE api.consent (
    user_id          text NOT NULL,
    capability       text NOT NULL,
    state            text NOT NULL,
    changed_at       timestamptz NOT NULL DEFAULT now(),
    changed_via      text NOT NULL,
    first_granted_at timestamptz,
    PRIMARY KEY (user_id, capability),
    CONSTRAINT consent_state CHECK (state IN ('granted', 'withheld'))
);

CREATE INDEX consent_granted_idx ON api.consent (capability)
    WHERE state = 'granted';

CREATE TABLE api.consent_log (
    id         bigserial PRIMARY KEY,
    user_id    text NOT NULL,
    capability text NOT NULL,
    state      text NOT NULL,
    via        text NOT NULL,
    at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX consent_log_at_idx ON api.consent_log (at DESC);

CREATE TABLE api.token (
    id            bigserial PRIMARY KEY,
    owner_user_id text NOT NULL,
    name          text NOT NULL,
    prefix        text NOT NULL,
    digest        text NOT NULL UNIQUE,
    rate_limit    integer,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_used_at  timestamptz,
    revoked_at    timestamptz,
    revoked_by    text,
    CONSTRAINT token_rate_limit_sane CHECK (rate_limit IS NULL OR rate_limit > 0)
);

CREATE INDEX token_owner_idx ON api.token (owner_user_id)
    WHERE revoked_at IS NULL;

CREATE TABLE api.setting (
    key        text PRIMARY KEY,
    value      integer NOT NULL,
    changed_by text,
    changed_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO api.setting (key, value) VALUES
    ('rate_per_minute', 100),
    ('batch_max', 100),
    ('tokens_per_owner', 3);

CREATE TABLE api.request_log (
    id              bigserial PRIMARY KEY,
    token_id        bigint NOT NULL REFERENCES api.token (id),
    channel_id      text,
    subject_user_id text,
    outcome         text NOT NULL,
    at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX request_log_subject_idx ON api.request_log (subject_user_id, at DESC);
CREATE INDEX request_log_token_idx ON api.request_log (token_id, at DESC);
