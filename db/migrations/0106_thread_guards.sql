CREATE TABLE fd.thread_guards (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    state text NOT NULL DEFAULT 'warned',
    opened_by text NOT NULL,
    reason text NOT NULL,
    case_id bigint REFERENCES fd.cases(id),
    expires_at timestamptz,
    warned_ts text,
    warned_at timestamptz,
    started_at timestamptz,
    finished_at timestamptz,
    passes integer NOT NULL DEFAULT 0,
    deleted_count integer NOT NULL DEFAULT 0,
    transcript_sha text,
    error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT thread_guards_kind_known CHECK (kind IN ('lock', 'destroy')),
    CONSTRAINT thread_guards_state_known
        CHECK (state IN ('warned', 'running', 'done', 'failed')),
    CONSTRAINT thread_guards_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT thread_guards_lock_expires CHECK (kind <> 'lock' OR expires_at IS NOT NULL)
);

CREATE UNIQUE INDEX thread_guards_one_live
    ON fd.thread_guards (channel_id, thread_ts)
    WHERE state IN ('warned', 'running');

CREATE INDEX thread_guards_pending ON fd.thread_guards (created_at)
    WHERE state IN ('warned', 'running');

CREATE INDEX thread_guards_lifting ON fd.thread_guards (expires_at)
    WHERE kind = 'lock' AND state = 'running';

COMMENT ON TABLE fd.thread_guards IS
    'A thread the Fire Department has locked or is destroying. The row is the intent; a worker carries it out, so a restart mid-destroy resumes rather than leaving the thread half gone.';

CREATE TABLE fd.thread_guard_strikes (
    guard_id bigint NOT NULL REFERENCES fd.thread_guards(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    messages integer NOT NULL DEFAULT 0,
    first_at timestamptz NOT NULL DEFAULT now(),
    last_at timestamptz NOT NULL DEFAULT now(),
    reset_at timestamptz,
    reset_outcome text,
    PRIMARY KEY (guard_id, user_id)
);

CREATE INDEX thread_guard_strikes_reset ON fd.thread_guard_strikes (reset_at)
    WHERE reset_at IS NOT NULL;

COMMENT ON TABLE fd.thread_guard_strikes IS
    'Who kept posting after the warning, and whether their Slack sessions were reset for it. Counted per guard so one bad thread cannot follow somebody to the next one.';

CREATE OR REPLACE FUNCTION fd.thread_guard_changed() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_thread_guard', COALESCE(NEW.id, OLD.id)::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER thread_guards_changed
    AFTER INSERT OR UPDATE OF state, expires_at OR DELETE ON fd.thread_guards
    FOR EACH ROW EXECUTE FUNCTION fd.thread_guard_changed();
