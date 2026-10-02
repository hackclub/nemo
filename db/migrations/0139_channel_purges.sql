CREATE TABLE fd.channel_purges (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id text NOT NULL,
    wanted integer NOT NULL,
    reason text NOT NULL,
    state text NOT NULL DEFAULT 'asked',
    case_id bigint REFERENCES fd.cases(id),
    asked_by text NOT NULL,
    asked_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    taken_down integer NOT NULL DEFAULT 0,
    transcript jsonb NOT NULL DEFAULT '[]'::jsonb,
    error text,
    CONSTRAINT channel_purges_state_known
        CHECK (state IN ('asked', 'running', 'done', 'failed')),
    CONSTRAINT channel_purges_wanted_sane CHECK (wanted BETWEEN 1 AND 100),
    CONSTRAINT channel_purges_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT channel_purges_finished_together
        CHECK ((state IN ('done', 'failed')) = (finished_at IS NOT NULL))
);

CREATE UNIQUE INDEX channel_purges_one_running
    ON fd.channel_purges (channel_id)
    WHERE state IN ('asked', 'running');

CREATE INDEX channel_purges_waiting ON fd.channel_purges (asked_at)
    WHERE state = 'asked';

CREATE INDEX channel_purges_recent ON fd.channel_purges (channel_id, asked_at DESC);

CREATE OR REPLACE FUNCTION fd.channel_purge_asked() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_channel_purge', NEW.id::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER channel_purges_asked
    AFTER INSERT ON fd.channel_purges
    FOR EACH ROW EXECUTE FUNCTION fd.channel_purge_asked();
