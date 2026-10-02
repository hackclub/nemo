CREATE TABLE fd.member_guards (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL,
    subject_id text NOT NULL,
    channel_id text,
    state text NOT NULL DEFAULT 'live',
    carry text NOT NULL DEFAULT 'pending',
    carried_by text NOT NULL DEFAULT 'nemo',
    case_id bigint REFERENCES fd.cases(id),
    opened_by text NOT NULL,
    opened_at timestamptz NOT NULL DEFAULT now(),
    reason text NOT NULL,
    expires_at timestamptz,
    lifted_at timestamptz,
    lifted_by text,
    lift_reason text,
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT member_guards_kind_known CHECK (kind IN ('shush', 'channel_ban')),
    CONSTRAINT member_guards_state_known CHECK (state IN ('live', 'lifting', 'lifted')),
    CONSTRAINT member_guards_carry_known CHECK (carry IN ('pending', 'held', 'failed')),
    CONSTRAINT member_guards_carried_by_known CHECK (carried_by IN ('nemo', 'by_hand')),
    CONSTRAINT member_guards_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT member_guards_lifted_together
        CHECK ((state = 'lifted') = (lifted_at IS NOT NULL)),
    CONSTRAINT member_guards_by_hand_is_held
        CHECK (carried_by <> 'by_hand' OR carry = 'held'),
    CONSTRAINT member_guards_channel_scope
        CHECK ((channel_id IS NOT NULL) = (kind IN ('channel_ban')))
);

CREATE UNIQUE INDEX member_guards_one_live
    ON fd.member_guards (subject_id, kind, coalesce(channel_id, ''))
    WHERE state IN ('live', 'lifting');

CREATE INDEX member_guards_standing ON fd.member_guards (subject_id)
    WHERE state = 'live';

CREATE INDEX member_guards_orphaned ON fd.member_guards (opened_at)
    WHERE state = 'live' AND case_id IS NULL;

CREATE INDEX member_guards_lifting ON fd.member_guards (expires_at)
    WHERE state = 'live' AND expires_at IS NOT NULL;

CREATE INDEX member_guards_stuck ON fd.member_guards (updated_at)
    WHERE carry = 'failed';

CREATE INDEX member_guards_case ON fd.member_guards (case_id)
    WHERE case_id IS NOT NULL;

CREATE TABLE fd.member_guard_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guard_id bigint NOT NULL REFERENCES fd.member_guards(id) ON DELETE CASCADE,
    subject_id text NOT NULL,
    channel_id text,
    verb text NOT NULL,
    message_ts text,
    permalink text,
    told_ts text,
    told_until timestamptz,
    detail text,
    at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT member_guard_events_verb_known
        CHECK (verb IN ('held', 'released', 'failed', 'deleted', 'kicked', 'let_past', 'told'))
);

CREATE INDEX member_guard_events_recent
    ON fd.member_guard_events (guard_id, at DESC);

CREATE INDEX member_guard_events_by_subject
    ON fd.member_guard_events (subject_id, at DESC);

CREATE INDEX member_guard_events_still_telling
    ON fd.member_guard_events (guard_id, told_until DESC)
    WHERE told_until IS NOT NULL;

ALTER TABLE fd.actions
    ADD COLUMN guard_id bigint REFERENCES fd.member_guards(id) ON DELETE SET NULL;

CREATE INDEX actions_guard_idx ON fd.actions (guard_id)
    WHERE guard_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fd.member_guard_changed() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_member_guard', COALESCE(NEW.subject_id, OLD.subject_id));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER member_guards_changed
    AFTER INSERT OR UPDATE OF state, carry, expires_at, case_id OR DELETE
    ON fd.member_guards
    FOR EACH ROW EXECUTE FUNCTION fd.member_guard_changed();
