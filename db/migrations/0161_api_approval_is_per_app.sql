CREATE TABLE api.approval_per_app (
    app_id     bigint PRIMARY KEY REFERENCES api.app (id),
    granted_by text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_by text,
    revoked_at timestamptz
);

INSERT INTO api.approval_per_app (app_id, granted_by, granted_at)
SELECT DISTINCT ON (app_id) app_id, granted_by, granted_at
FROM api.approval
WHERE revoked_at IS NULL
ORDER BY app_id, granted_at;

DROP TABLE api.approval;

ALTER TABLE api.approval_per_app RENAME TO approval;

CREATE INDEX approval_live_idx ON api.approval (app_id) WHERE revoked_at IS NULL;

DROP INDEX IF EXISTS api.access_request_one_open_idx;

DELETE FROM api.access_request a
WHERE EXISTS (
    SELECT 1 FROM api.access_request b
    WHERE b.app_id = a.app_id AND b.state = 'pending' AND b.id < a.id AND a.state = 'pending'
);

ALTER TABLE api.access_request DROP COLUMN scope;

CREATE UNIQUE INDEX access_request_one_open_idx
    ON api.access_request (app_id) WHERE state = 'pending';
