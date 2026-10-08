ALTER TABLE fd.channel_guard_events
    ADD COLUMN remove_pending boolean NOT NULL DEFAULT false,
    ADD COLUMN remove_attempts integer NOT NULL DEFAULT 0;

CREATE INDEX channel_guard_events_remove_pending
    ON fd.channel_guard_events (id)
    WHERE remove_pending;

CREATE OR REPLACE FUNCTION fd.channel_guard_remove_pending() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_guard_remove', NEW.guard_id::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER channel_guard_events_remove_pending
    AFTER INSERT ON fd.channel_guard_events
    FOR EACH ROW WHEN (NEW.remove_pending)
    EXECUTE FUNCTION fd.channel_guard_remove_pending();
