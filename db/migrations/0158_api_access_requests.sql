CREATE TABLE api.access_request (
    id         bigserial PRIMARY KEY,
    user_id    text NOT NULL,
    scope      text NOT NULL,
    reason     text NOT NULL,
    state      text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_by text,
    decided_at timestamptz,
    note       text,
    CONSTRAINT access_request_state_known
        CHECK (state IN ('pending', 'approved', 'declined', 'withdrawn')),
    CONSTRAINT access_request_decided_together
        CHECK ((state = 'pending') = (decided_at IS NULL))
);

CREATE UNIQUE INDEX access_request_one_open_idx
    ON api.access_request (user_id, scope) WHERE state = 'pending';

CREATE INDEX access_request_queue_idx
    ON api.access_request (created_at DESC) WHERE state = 'pending';

CREATE INDEX access_request_owner_idx ON api.access_request (user_id, created_at DESC);

CREATE TABLE api.approval (
    user_id    text NOT NULL,
    scope      text NOT NULL,
    granted_by text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_by text,
    revoked_at timestamptz,
    PRIMARY KEY (user_id, scope)
);

CREATE INDEX approval_live_idx ON api.approval (scope) WHERE revoked_at IS NULL;

ALTER TABLE api.token ADD COLUMN rotated_at timestamptz;
