ALTER TABLE fd.member_guards
    ADD COLUMN starts_at timestamptz,
    ADD COLUMN cancelled_at timestamptz,
    ADD COLUMN cancelled_by text,
    ADD COLUMN cancel_reason text;

ALTER TABLE fd.member_guards
    DROP CONSTRAINT member_guards_state_known,
    ADD CONSTRAINT member_guards_state_known
        CHECK (state IN ('scheduled', 'live', 'lifting', 'lifted', 'cancelled')),
    ADD CONSTRAINT member_guards_cancelled_together
        CHECK ((state = 'cancelled') = (cancelled_at IS NOT NULL)),
    ADD CONSTRAINT member_guards_scheduled_deactivation
        CHECK (state <> 'scheduled' OR (kind = 'deactivation' AND starts_at IS NOT NULL)),
    ADD CONSTRAINT member_guards_ends_after_start
        CHECK (expires_at IS NULL OR starts_at IS NULL OR expires_at > starts_at);

CREATE UNIQUE INDEX member_guards_one_scheduled
    ON fd.member_guards (subject_id, kind)
    WHERE state = 'scheduled';

CREATE INDEX member_guards_due ON fd.member_guards (starts_at)
    WHERE state = 'scheduled';

DROP TRIGGER member_guards_changed ON fd.member_guards;

CREATE TRIGGER member_guards_changed
    AFTER INSERT OR UPDATE OF state, enforcement_status, expires_at, starts_at, case_id OR DELETE
    ON fd.member_guards
    FOR EACH ROW EXECUTE FUNCTION fd.member_guard_changed();

DROP TRIGGER member_guards_wake_purges ON fd.member_guards;

CREATE TRIGGER member_guards_wake_purges
    AFTER UPDATE OF enforcement_status, state ON fd.member_guards
    FOR EACH ROW
    WHEN ((NEW.enforcement_status = 'held' AND OLD.enforcement_status IS DISTINCT FROM 'held')
          OR (NEW.state IN ('lifted', 'cancelled') AND OLD.state IS DISTINCT FROM NEW.state))
    EXECUTE FUNCTION fd.purge_guard_settled();
