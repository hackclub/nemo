CREATE OR REPLACE VIEW app.effective_role AS
SELECT g.user_id, g.name AS role
FROM app.grant g
WHERE g.kind = 'role' AND g.revoked_at IS NULL;

CREATE OR REPLACE VIEW app.effective_capability AS
WITH held AS (
    SELECT r.user_id, r.role FROM app.effective_role r
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

DROP TABLE IF EXISTS fd.role_permissions;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT ON app.effective_role TO rails_app';
    EXECUTE 'GRANT SELECT ON app.effective_role TO pipeline_writer';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO rails_app';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN NULL;
END
$$;
