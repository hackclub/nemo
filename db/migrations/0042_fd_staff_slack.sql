CREATE TABLE fd.staff_slack (
    staff_user_id text PRIMARY KEY,
    team_id text NOT NULL,
    scopes text NOT NULL,
    user_token text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    last_error text,
    last_error_at timestamptz,
    revoked_at timestamptz,
    revoked_by text,
    CONSTRAINT staff_slack_revoked_together CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
    CONSTRAINT staff_slack_error_together CHECK ((last_error IS NULL) = (last_error_at IS NULL))
);

CREATE INDEX staff_slack_live_idx ON fd.staff_slack (staff_user_id) WHERE revoked_at IS NULL;
