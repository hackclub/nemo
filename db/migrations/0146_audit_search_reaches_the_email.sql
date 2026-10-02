DROP INDEX IF EXISTS slack.audit_event_search_idx;

ALTER TABLE slack.audit_event DROP COLUMN IF EXISTS searchable;

ALTER TABLE slack.audit_event
    ADD COLUMN searchable tsvector
    GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig,
            coalesce(action, '') || ' ' ||
            coalesce(actor_id, '') || ' ' ||
            coalesce(entity_id, '') || ' ' ||
            coalesce(entity_kind, '') || ' ' ||
            coalesce(context ->> 'ip_address', '') || ' ' ||
            coalesce(context #>> '{app,name}', '') || ' ' ||
            coalesce(payload #>> '{actor,user,email}', '') || ' ' ||
            coalesce(payload #>> '{actor,user,name}', '') || ' ' ||
            coalesce(payload #>> '{entity,user,email}', '') || ' ' ||
            coalesce(payload #>> '{entity,user,name}', '') || ' ' ||
            coalesce(payload #>> '{entity,channel,name}', ''))
    ) STORED;

CREATE INDEX audit_event_search_idx ON slack.audit_event USING gin (searchable);

CREATE INDEX IF NOT EXISTS audit_event_actor_email_idx
    ON slack.audit_event ((lower(payload #>> '{actor,user,email}')))
    WHERE payload #>> '{actor,user,email}' IS NOT NULL;
