INSERT INTO app.grant (user_id, kind, name, effect, granted_by, granted_at, reason)
SELECT s.user_id, 'role', 'community_manager', 'allow', 'migration', now(),
       'held the community manager flag'
FROM app.staff s
WHERE s.community_manager
  AND NOT EXISTS (
      SELECT 1 FROM app.grant g
      WHERE g.user_id = s.user_id AND g.kind = 'role'
        AND g.name = 'community_manager' AND g.revoked_at IS NULL
  );

INSERT INTO app.grant (user_id, kind, name, effect, granted_by, granted_at, reason)
SELECT a.user_id, 'role', 'firefighter', 'allow', a.granted_by, a.granted_at,
       coalesce(a.reason, 'carried from fd.access_grants')
FROM fd.access_grants a
WHERE a.revoked_at IS NULL
  AND a.role IN ('firefighter', 'lead')
  AND NOT EXISTS (
      SELECT 1 FROM app.grant g
      WHERE g.user_id = a.user_id AND g.kind = 'role' AND g.revoked_at IS NULL
  );

INSERT INTO app.grant (user_id, kind, name, effect, granted_by, granted_at, reason)
SELECT c.user_id, 'role', 'community_manager', 'allow', c.granted_by, c.granted_at,
       'was a curator, which is now a manager'
FROM app.community_grants c
WHERE c.revoked_at IS NULL AND c.family = 'read' AND c.role = 'curator'
  AND NOT EXISTS (
      SELECT 1 FROM app.grant g
      WHERE g.user_id = c.user_id AND g.kind = 'role'
        AND g.name = 'community_manager' AND g.revoked_at IS NULL
  );

INSERT INTO app.grant (user_id, kind, name, effect, granted_by, granted_at, reason)
SELECT c.user_id, 'capability', want.name, 'allow', c.granted_by, c.granted_at,
       'carried from community role ' || c.role
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
  AND NOT EXISTS (
      SELECT 1 FROM app.grant g
      WHERE g.user_id = c.user_id AND g.kind = 'capability'
        AND g.name = want.name AND g.revoked_at IS NULL
  );

INSERT INTO app.grant (user_id, kind, name, effect, granted_by, granted_at, reason)
SELECT DISTINCT cg.user_id, 'role', 'promethean', 'allow', 'migration', now(),
       'holds channels individually'
FROM app.channel_grants cg
WHERE cg.revoked_at IS NULL AND cg.user_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM app.grant g
      WHERE g.user_id = cg.user_id AND g.kind = 'role' AND g.revoked_at IS NULL
  );

ALTER TABLE app.channel_audience DROP CONSTRAINT IF EXISTS channel_audience_kind;

UPDATE app.channel_audience SET audience = 'public' WHERE audience = 'everyone';
UPDATE app.channel_audience SET audience = 'granted' WHERE audience IN ('shared', 'private');

ALTER TABLE app.channel_audience ADD CONSTRAINT channel_audience_kind
    CHECK (audience IN ('granted', 'public'));
