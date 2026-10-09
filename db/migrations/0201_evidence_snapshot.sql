CREATE TABLE IF NOT EXISTS fd.evidence_snapshot (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        text        NOT NULL,
    deactivated_at timestamptz NOT NULL,
    taken_at       timestamptz NOT NULL DEFAULT now(),
    source         text        NOT NULL,
    guard_id       bigint,
    actor_id       text,
    reason         text,
    identity       jsonb       NOT NULL,
    cluster        jsonb,
    traits         jsonb       NOT NULL,
    links          jsonb       NOT NULL,
    CONSTRAINT evidence_snapshot_source_known CHECK (source IN ('fire_engine', 'slack'))
);

CREATE INDEX IF NOT EXISTS evidence_snapshot_member_idx ON fd.evidence_snapshot (user_id, deactivated_at DESC);

CREATE OR REPLACE FUNCTION fd.snapshot_evidence(who text, deactivated timestamptz, taken_by text,
                                                guard bigint, actor text, why text)
RETURNS bigint
LANGUAGE sql
AS $$
    INSERT INTO fd.evidence_snapshot
        (user_id, deactivated_at, source, guard_id, actor_id, reason, identity, cluster, traits, links)
    SELECT who, deactivated, taken_by, guard, actor, why,
           (SELECT jsonb_strip_nulls(jsonb_build_object(
                       'handle', m.handle, 'display_name', m.display_name,
                       'real_name', i.real_name, 'email', i.email))
            FROM (SELECT 1) one
            LEFT JOIN fd.member m ON m.user_id = who
            LEFT JOIN fd.member_identity i ON i.user_id = who),
           (SELECT to_jsonb(c) - 'user_id' FROM fd.member_cluster c WHERE c.user_id = who),
           coalesce((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                'kind', t.kind, 'value', t.value, 'agent', a.ua,
                                'first_seen', t.first_seen, 'last_seen', t.last_seen, 'seen', t.seen))
                            ORDER BY t.kind, t.value)
                     FROM fd.member_trait t
                     LEFT JOIN slack.user_agent a ON t.kind = 'ua_id' AND a.id::text = t.value
                     WHERE t.user_id = who), '[]'::jsonb),
           coalesce((SELECT jsonb_agg(jsonb_build_object(
                                'other', CASE WHEN l.a_user_id = who THEN l.b_user_id ELSE l.a_user_id END,
                                'score', l.score, 'top_signal', l.top_signal, 'top_family', l.top_family,
                                'families', l.families, 'signals', l.signals, 'label', l.label,
                                'first_seen', l.first_seen, 'last_seen', l.last_seen)
                            ORDER BY l.score DESC, l.a_user_id, l.b_user_id)
                     FROM fd.member_link l
                     WHERE l.a_user_id = who OR l.b_user_id = who), '[]'::jsonb)
    RETURNING id
$$;

CREATE OR REPLACE FUNCTION fd.guard_deactivation_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fd.snapshot_evidence(NEW.subject_id, NEW.at, 'fire_engine', g.id, g.opened_by, g.reason)
    FROM fd.member_guards g
    WHERE g.id = NEW.guard_id;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION fd.audit_deactivation_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.entity_id IS NULL OR NEW.at < now() - interval '1 day' THEN
        RETURN NULL;
    END IF;
    IF EXISTS (SELECT 1 FROM fd.evidence_snapshot s
               WHERE s.user_id = NEW.entity_id
                 AND s.deactivated_at BETWEEN NEW.at - interval '1 hour' AND NEW.at + interval '1 hour') THEN
        RETURN NULL;
    END IF;
    PERFORM fd.snapshot_evidence(NEW.entity_id, NEW.at, 'slack', NULL, NEW.actor_id, NULL);
    RETURN NULL;
END
$$;

CREATE TRIGGER member_guard_deactivation_snapshot
    AFTER INSERT ON fd.member_guard_events
    FOR EACH ROW
    WHEN (NEW.verb = 'deactivated')
    EXECUTE FUNCTION fd.guard_deactivation_snapshot();

CREATE TRIGGER audit_event_deactivation_snapshot
    AFTER INSERT ON slack.audit_event
    FOR EACH ROW
    WHEN (NEW.action = 'user_deactivated')
    EXECUTE FUNCTION fd.audit_deactivation_snapshot();

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT ON fd.evidence_snapshot TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.evidence_snapshot TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.evidence_snapshot FROM dbt_owner;
    END IF;
END
$$;
