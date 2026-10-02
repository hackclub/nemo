CREATE TABLE api.app (
    id            bigserial PRIMARY KEY,
    slug          text NOT NULL UNIQUE,
    name          text NOT NULL,
    blurb         text NOT NULL,
    owner_user_id text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    retired_at    timestamptz
);

CREATE INDEX app_owner_idx ON api.app (owner_user_id);
CREATE INDEX app_live_idx ON api.app (name) WHERE retired_at IS NULL;

DROP TABLE api.approval;

CREATE TABLE api.approval (
    app_id     bigint NOT NULL REFERENCES api.app (id),
    scope      text NOT NULL,
    granted_by text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_by text,
    revoked_at timestamptz,
    PRIMARY KEY (app_id, scope)
);

CREATE INDEX approval_live_idx ON api.approval (scope) WHERE revoked_at IS NULL;

DROP TABLE api.consent;
DROP TABLE api.consent_log;

CREATE TABLE api.consent (
    user_id          text NOT NULL,
    app_id           bigint NOT NULL REFERENCES api.app (id),
    capability       text NOT NULL,
    state            text NOT NULL,
    changed_at       timestamptz NOT NULL DEFAULT now(),
    changed_via      text NOT NULL,
    first_granted_at timestamptz,
    PRIMARY KEY (user_id, app_id, capability),
    CONSTRAINT consent_state CHECK (state IN ('granted', 'withheld'))
);

CREATE INDEX consent_granted_idx ON api.consent (app_id, capability)
    WHERE state = 'granted';

CREATE TABLE api.consent_log (
    id         bigserial PRIMARY KEY,
    user_id    text NOT NULL,
    app_id     bigint NOT NULL REFERENCES api.app (id),
    capability text NOT NULL,
    state      text NOT NULL,
    via        text NOT NULL,
    at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX consent_log_at_idx ON api.consent_log (at DESC);

DELETE FROM api.request_log;
DELETE FROM api.token;

ALTER TABLE api.token ADD COLUMN app_id bigint NOT NULL REFERENCES api.app (id);

CREATE INDEX token_app_idx ON api.token (app_id);

DELETE FROM api.access_request;

ALTER TABLE api.access_request DROP COLUMN user_id;
ALTER TABLE api.access_request ADD COLUMN app_id bigint NOT NULL REFERENCES api.app (id);

DROP INDEX IF EXISTS api.access_request_one_open_idx;
DROP INDEX IF EXISTS api.access_request_owner_idx;

CREATE UNIQUE INDEX access_request_one_open_idx
    ON api.access_request (app_id, scope) WHERE state = 'pending';

CREATE INDEX access_request_app_idx ON api.access_request (app_id, created_at DESC);
