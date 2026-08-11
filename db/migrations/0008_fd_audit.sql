CREATE TABLE fd.audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    actor_user_id text,
    actor_kind text NOT NULL,
    entity_type text NOT NULL,
    entity_id bigint NOT NULL,
    verb text NOT NULL,
    before jsonb,
    after jsonb,
    source_app text NOT NULL,
    request_id text,
    CONSTRAINT audit_actor_kind_check CHECK (
        actor_kind IN ('human', 'bot', 'system', 'import')
    )
);

CREATE INDEX audit_entity_idx ON fd.audit (entity_type, entity_id, occurred_at DESC);

CREATE INDEX audit_actor_idx ON fd.audit (actor_user_id, occurred_at DESC)
    WHERE actor_user_id IS NOT NULL;

DO $$
DECLARE
    role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['rails_app', 'pipeline_writer'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('REVOKE UPDATE, DELETE ON fd.audit FROM %I', role_name);
        END IF;
    END LOOP;
END
$$;
