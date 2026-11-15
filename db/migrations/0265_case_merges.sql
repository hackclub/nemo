CREATE TABLE fd.case_merges (
    id                bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id           bigint      NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    into_case_id      bigint      NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    prior_resolved_at timestamptz,
    prior_resolution  text,
    merged_at         timestamptz NOT NULL DEFAULT now(),
    unmerged_at       timestamptz,
    CONSTRAINT case_merges_not_self CHECK (case_id <> into_case_id),
    CONSTRAINT case_merges_prior_together CHECK ((prior_resolved_at IS NULL) = (prior_resolution IS NULL))
);

CREATE UNIQUE INDEX case_merges_live_idx ON fd.case_merges (case_id) WHERE unmerged_at IS NULL;
CREATE INDEX case_merges_into_idx ON fd.case_merges (into_case_id) WHERE unmerged_at IS NULL;

ALTER TABLE fd.case_tags ADD COLUMN merge_id bigint REFERENCES fd.case_merges(id) ON DELETE SET NULL;
CREATE INDEX case_tags_merge_idx ON fd.case_tags (merge_id) WHERE merge_id IS NOT NULL;

INSERT INTO fd.case_merges (case_id, into_case_id, prior_resolved_at, prior_resolution, merged_at)
SELECT c.id, c.duplicate_of,
       CASE WHEN prior.resolution IS NOT NULL THEN coalesce(prior.resolved_at, c.resolved_at) END,
       CASE WHEN coalesce(prior.resolved_at, c.resolved_at) IS NOT NULL THEN prior.resolution END,
       coalesce(prior.occurred_at, c.resolved_at, c.updated_at)
FROM fd.cases c
LEFT JOIN LATERAL (
    SELECT a.occurred_at,
           nullif(a.before ->> 'resolution', 'duplicate') AS resolution,
           CASE WHEN a.before ->> 'resolved_at' ~ '^\d{4}-\d{2}-\d{2}'
                THEN (a.before ->> 'resolved_at')::timestamptz END AS resolved_at
    FROM fd.audit a
    WHERE a.entity_type = 'case' AND a.entity_id = c.id AND a.verb = 'resolved'
      AND a.after ->> 'resolution' = 'duplicate'
    ORDER BY a.occurred_at DESC, a.id DESC
    LIMIT 1
) prior ON true
WHERE c.duplicate_of IS NOT NULL AND c.duplicate_of <> c.id;

CREATE FUNCTION fd.case_merge_changed() RETURNS trigger AS $$
DECLARE
    ended fd.case_merges%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        UPDATE fd.case_merges SET unmerged_at = now()
        WHERE case_id = NEW.id AND unmerged_at IS NULL
        RETURNING * INTO ended;
    END IF;

    IF NEW.duplicate_of IS NULL THEN
        RETURN NULL;
    END IF;

    IF ended.id IS NOT NULL THEN
        INSERT INTO fd.case_merges (case_id, into_case_id, prior_resolved_at, prior_resolution)
        VALUES (NEW.id, NEW.duplicate_of, ended.prior_resolved_at, ended.prior_resolution);
    ELSIF TG_OP = 'UPDATE' AND OLD.resolution IS DISTINCT FROM 'duplicate' THEN
        INSERT INTO fd.case_merges (case_id, into_case_id, prior_resolved_at, prior_resolution)
        VALUES (NEW.id, NEW.duplicate_of, OLD.resolved_at, OLD.resolution);
    ELSE
        INSERT INTO fd.case_merges (case_id, into_case_id) VALUES (NEW.id, NEW.duplicate_of);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cases_merge_inserted
    AFTER INSERT ON fd.cases
    FOR EACH ROW WHEN (NEW.duplicate_of IS NOT NULL)
    EXECUTE FUNCTION fd.case_merge_changed();

CREATE TRIGGER cases_merge_changed
    AFTER UPDATE OF duplicate_of ON fd.cases
    FOR EACH ROW WHEN (OLD.duplicate_of IS DISTINCT FROM NEW.duplicate_of)
    EXECUTE FUNCTION fd.case_merge_changed();
