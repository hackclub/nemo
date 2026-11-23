CREATE TABLE fd.photo_removals (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id text NOT NULL,
    asked_by text NOT NULL,
    guard_id bigint REFERENCES fd.member_guards(id) ON DELETE SET NULL,
    reason text,
    state text NOT NULL DEFAULT 'asked',
    attempts integer NOT NULL DEFAULT 0,
    error text,
    avatar_url text,
    avatar_hash text,
    asked_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    CONSTRAINT photo_removals_state_known CHECK (state IN ('asked', 'running', 'done', 'failed')),
    CONSTRAINT photo_removals_member_present CHECK (btrim(member_id) <> ''),
    CONSTRAINT photo_removals_reason_present CHECK (reason IS NULL OR btrim(reason) <> ''),
    CONSTRAINT photo_removals_finished_together
        CHECK ((state IN ('done', 'failed')) = (finished_at IS NOT NULL))
);

CREATE UNIQUE INDEX photo_removals_one_waiting
    ON fd.photo_removals (member_id)
    WHERE state IN ('asked', 'running');

CREATE INDEX photo_removals_asked ON fd.photo_removals (asked_at) WHERE state = 'asked';

CREATE INDEX photo_removals_member_recent ON fd.photo_removals (member_id, asked_at DESC);

CREATE TABLE fd.photo_removal_evidence (
    removal_id bigint PRIMARY KEY REFERENCES fd.photo_removals(id) ON DELETE CASCADE,
    image bytea NOT NULL,
    content_type text NOT NULL,
    sha256 text NOT NULL,
    stored_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT photo_removal_evidence_sha256_shape CHECK (sha256 ~ '^[0-9a-f]{64}$')
);

CREATE FUNCTION fd.photo_removal_asked() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_photo_removal', NEW.id::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER photo_removals_asked
    AFTER INSERT OR UPDATE OF state ON fd.photo_removals
    FOR EACH ROW WHEN (NEW.state = 'asked')
    EXECUTE FUNCTION fd.photo_removal_asked();

CREATE FUNCTION fd.photo_removal_guard_settled() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_photo_removal', r.id::text)
    FROM fd.photo_removals r
    WHERE r.guard_id = NEW.id AND r.state = 'asked';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER member_guards_wake_photo_removals
    AFTER UPDATE OF enforcement_status, state ON fd.member_guards
    FOR EACH ROW
    WHEN ((NEW.enforcement_status = 'held' AND OLD.enforcement_status IS DISTINCT FROM 'held')
          OR (NEW.state IN ('lifted', 'cancelled') AND OLD.state IS DISTINCT FROM NEW.state))
    EXECUTE FUNCTION fd.photo_removal_guard_settled();
