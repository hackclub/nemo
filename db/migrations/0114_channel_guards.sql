CREATE TABLE fd.channel_guards (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL,
    channel_id text NOT NULL,
    state text NOT NULL DEFAULT 'live',
    settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    opened_by text NOT NULL,
    reason text NOT NULL,
    case_id bigint REFERENCES fd.cases(id),
    lifted_at timestamptz,
    lifted_by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT channel_guards_kind_known CHECK (kind IN ('bot_allowlist')),
    CONSTRAINT channel_guards_state_known CHECK (state IN ('live', 'lifted')),
    CONSTRAINT channel_guards_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT channel_guards_lifted_together
        CHECK ((state = 'lifted') = (lifted_at IS NOT NULL))
);

CREATE UNIQUE INDEX channel_guards_one_live
    ON fd.channel_guards (channel_id, kind)
    WHERE state = 'live';

CREATE INDEX channel_guards_standing ON fd.channel_guards (channel_id)
    WHERE state = 'live';

CREATE TABLE fd.channel_guard_allows (
    guard_id bigint NOT NULL REFERENCES fd.channel_guards(id) ON DELETE CASCADE,
    subject_id text NOT NULL,
    label text,
    added_by text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    reason text,
    PRIMARY KEY (guard_id, subject_id)
);

CREATE TABLE fd.channel_guard_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guard_id bigint NOT NULL REFERENCES fd.channel_guards(id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    subject_id text NOT NULL,
    verb text NOT NULL,
    message_ts text,
    permalink text,
    app_id text,
    told_ts text,
    told_until timestamptz,
    at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT channel_guard_events_verb_known
        CHECK (verb IN ('kicked', 'deleted', 'let_past'))
);

CREATE INDEX channel_guard_events_recent
    ON fd.channel_guard_events (channel_id, at DESC);

CREATE INDEX channel_guard_events_still_telling
    ON fd.channel_guard_events (guard_id, subject_id, told_until DESC)
    WHERE told_until IS NOT NULL;

CREATE OR REPLACE FUNCTION fd.channel_guard_changed() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_channel_guard', COALESCE(NEW.channel_id, OLD.channel_id));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER channel_guards_changed
    AFTER INSERT OR UPDATE OF state, settings OR DELETE ON fd.channel_guards
    FOR EACH ROW EXECUTE FUNCTION fd.channel_guard_changed();

CREATE OR REPLACE FUNCTION fd.channel_guard_allow_changed() RETURNS trigger AS $$
DECLARE
    room text;
BEGIN
    SELECT channel_id INTO room FROM fd.channel_guards
    WHERE id = COALESCE(NEW.guard_id, OLD.guard_id);

    IF room IS NOT NULL THEN
        PERFORM pg_notify('fd_channel_guard', room);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER channel_guard_allows_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.channel_guard_allows
    FOR EACH ROW EXECUTE FUNCTION fd.channel_guard_allow_changed();
