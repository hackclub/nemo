ALTER TABLE fd.audit ADD COLUMN IF NOT EXISTS subject_user_id text;

UPDATE fd.audit a
SET subject_user_id = t.target_user_id
FROM fd.actions t
WHERE a.entity_type = 'action' AND a.entity_id = t.id
  AND a.subject_user_id IS NULL AND t.target_user_id IS NOT NULL;

UPDATE fd.audit a
SET subject_user_id = n.subject_user_id
FROM fd.notes n
WHERE a.entity_type = 'note' AND a.entity_id = n.id
  AND a.subject_user_id IS NULL AND n.subject_user_id IS NOT NULL;

UPDATE fd.audit a
SET subject_user_id = g.subject_id
FROM fd.member_guards g
WHERE a.entity_type = 'member_guard' AND a.entity_id = g.id
  AND a.subject_user_id IS NULL;

UPDATE fd.audit
SET subject_user_id = coalesce(after ->> 'user_id', after ->> 'subject_user_id',
                               after ->> 'target_user_id')
WHERE subject_user_id IS NULL
  AND coalesce(after ->> 'user_id', after ->> 'subject_user_id',
               after ->> 'target_user_id') ~ '^[UW][A-Z0-9]{2,}$';

ALTER TABLE fd.audit
    ADD COLUMN IF NOT EXISTS searchable tsvector
    GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig,
            coalesce(verb, '') || ' ' ||
            coalesce(entity_type, '') || ' ' ||
            coalesce(actor_user_id, '') || ' ' ||
            coalesce(entity_ref, '') || ' ' ||
            coalesce(subject_user_id, '') || ' ' ||
            coalesce(entity_id::text, ''))
        ||
        jsonb_to_tsvector('simple'::regconfig, coalesce(before, '{}'::jsonb), '["string"]')
        ||
        jsonb_to_tsvector('simple'::regconfig, coalesce(after, '{}'::jsonb), '["string"]')
    ) STORED;

CREATE INDEX IF NOT EXISTS audit_recent_idx ON fd.audit (occurred_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS audit_subject_idx ON fd.audit (subject_user_id, occurred_at DESC)
    WHERE subject_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_verb_idx ON fd.audit (verb, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_search_idx ON fd.audit USING gin (searchable);

ALTER TABLE slack.audit_event
    ADD COLUMN IF NOT EXISTS searchable tsvector
    GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig,
            coalesce(action, '') || ' ' ||
            coalesce(actor_id, '') || ' ' ||
            coalesce(entity_id, '') || ' ' ||
            coalesce(entity_kind, '') || ' ' ||
            coalesce(context ->> 'ip_address', '') || ' ' ||
            coalesce(context #>> '{app,name}', ''))
    ) STORED;

CREATE INDEX IF NOT EXISTS audit_event_search_idx ON slack.audit_event USING gin (searchable);
