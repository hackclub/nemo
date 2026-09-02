CREATE OR REPLACE VIEW app.effective_capability AS
WITH held AS (
    SELECT s.user_id::text, 'community_manager'::text AS role
    FROM app.staff s WHERE s.community_manager
    UNION
    SELECT a.user_id::text,
           (CASE a.role WHEN 'lead' THEN 'firefighter' ELSE a.role END)::text
    FROM fd.access_grants a
    WHERE a.revoked_at IS NULL AND a.role IN ('firefighter', 'lead')
    UNION
    SELECT c.user_id::text, 'community_manager'::text
    FROM app.community_grants c
    WHERE c.revoked_at IS NULL AND c.family = 'read' AND c.role = 'curator'
    UNION
    SELECT g.user_id, g.name
    FROM app.grant g WHERE g.kind = 'role' AND g.revoked_at IS NULL
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
    UNION
    SELECT c.user_id::text, want.name::text
    FROM app.community_grants c
    CROSS JOIN LATERAL (
        SELECT unnest(
            CASE
                WHEN c.family = 'read' AND c.role IN ('analyst', 'curator')
                    THEN ARRAY['member.read']
                WHEN c.family = 'ops' AND c.role = 'operator'
                    THEN ARRAY['engine.read', 'engine.stage', 'channel.backfill']
                WHEN c.family = 'ops' AND c.role = 'steward'
                    THEN ARRAY['engine.read', 'engine.stage', 'channel.backfill',
                               'engine.sync', 'engine.tune']
                ELSE ARRAY[]::text[]
            END
        ) AS name
    ) AS want
    WHERE c.revoked_at IS NULL
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
    EXECUTE 'GRANT SELECT ON app.effective_capability TO rails_app';
    EXECUTE 'GRANT SELECT ON app.effective_capability TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN NULL;
END
$$;
