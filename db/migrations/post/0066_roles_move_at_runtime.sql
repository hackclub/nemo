CREATE TABLE IF NOT EXISTS app.role_override (
    role text NOT NULL REFERENCES app.role(name) ON DELETE CASCADE,
    capability text NOT NULL REFERENCES app.capability(key) ON DELETE CASCADE,
    allowed boolean NOT NULL,
    changed_by text NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (role, capability)
);

CREATE OR REPLACE VIEW app.effective_capability AS
WITH held AS (
    SELECT g.user_id, g.name AS role
    FROM app.grant g
    WHERE g.kind = 'role' AND g.revoked_at IS NULL
),
superadmin AS (
    SELECT DISTINCT h.user_id
    FROM held h JOIN app.role r ON r.name = h.role
    WHERE r.everything
),
baseline AS (
    SELECT h.user_id, c.key AS capability
    FROM held h
    CROSS JOIN app.capability c
    WHERE coalesce(
        (SELECT o.allowed FROM app.role_override o
          WHERE o.role = h.role AND o.capability = c.key),
        EXISTS (SELECT 1 FROM app.role_capability rc
                 WHERE rc.role = h.role AND rc.capability = c.key)
    )
),
added AS (
    SELECT g.user_id, g.name AS capability
    FROM app.grant g
    WHERE g.kind = 'capability' AND g.effect = 'allow' AND g.revoked_at IS NULL
),
denied AS (
    SELECT g.user_id, g.name AS capability
    FROM app.grant g
    WHERE g.kind = 'capability' AND g.effect = 'deny' AND g.revoked_at IS NULL
),
granted AS (
    SELECT user_id, capability, 'baseline' AS via FROM baseline
    UNION
    SELECT user_id, capability, 'added' AS via FROM added
)
SELECT s.user_id, c.key AS capability, 'superadmin' AS via
FROM superadmin s CROSS JOIN app.capability c
UNION
SELECT g.user_id, g.capability, min(g.via) AS via
FROM granted g
WHERE g.user_id NOT IN (SELECT user_id FROM superadmin)
  AND NOT EXISTS (
      SELECT 1 FROM denied d
      WHERE d.user_id = g.user_id AND d.capability = g.capability
  )
GROUP BY g.user_id, g.capability;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON app.role_override TO rails_app';
    EXECUTE 'GRANT SELECT ON app.role_override TO pipeline_writer';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO rails_app';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        RAISE NOTICE 'role_override: could not set role grants (%)', SQLERRM;
END
$$;
