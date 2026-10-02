ALTER TABLE fd.audit ADD COLUMN IF NOT EXISTS entity_ref text;

CREATE INDEX IF NOT EXISTS audit_entity_ref_idx ON fd.audit (entity_type, entity_ref)
    WHERE entity_ref IS NOT NULL;

UPDATE fd.audit
SET entity_ref = after->>'channel_id'
WHERE entity_type = 'channel_audience'
  AND entity_ref IS NULL
  AND after->>'channel_id' IS NOT NULL;

UPDATE fd.audit AS a
SET entity_id = t.case_id
FROM fd.case_threads AS t
WHERE a.entity_type = 'thread'
  AND a.verb = 'attached'
  AND a.entity_id = t.id
  AND a.entity_id <> t.case_id;

UPDATE fd.audit
SET entity_type = 'community_grant'
WHERE entity_type = 'grant'
  AND coalesce(after->>'role', before->>'role')
      IN ('observer', 'analyst', 'curator', 'operator', 'steward');
