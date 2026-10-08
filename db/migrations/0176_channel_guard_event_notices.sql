ALTER TABLE fd.channel_guard_events
    ADD COLUMN notice_wanted boolean NOT NULL DEFAULT false,
    ADD COLUMN noticed_at timestamptz,
    ADD COLUMN notice_attempts integer NOT NULL DEFAULT 0,
    ADD COLUMN detail text;

CREATE INDEX channel_guard_events_notice_pending
    ON fd.channel_guard_events (id)
    WHERE notice_wanted AND noticed_at IS NULL;

CREATE OR REPLACE FUNCTION fd.channel_guard_notice_wanted() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_guard_notice', NEW.guard_id::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER channel_guard_events_notice_wanted
    AFTER INSERT ON fd.channel_guard_events
    FOR EACH ROW WHEN (NEW.notice_wanted)
    EXECUTE FUNCTION fd.channel_guard_notice_wanted();
