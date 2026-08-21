ALTER TABLE fd.intake_outbox ADD COLUMN ticked_at timestamptz;

CREATE OR REPLACE FUNCTION fd.outbox_echoed() RETURNS trigger AS $$
BEGIN
    IF NEW.echoed_ts IS NOT NULL AND NEW.ticked_at IS NULL THEN
        PERFORM pg_notify('fd_outbox_waiting', NEW.conversation_id::text);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER intake_outbox_echoed
    AFTER UPDATE OF echoed_ts ON fd.intake_outbox
    FOR EACH ROW EXECUTE FUNCTION fd.outbox_echoed();

CREATE INDEX intake_outbox_unticked_idx
    ON fd.intake_outbox (conversation_id)
    WHERE echoed_ts IS NOT NULL AND ticked_at IS NULL;
