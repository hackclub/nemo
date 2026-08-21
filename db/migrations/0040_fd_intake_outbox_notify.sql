CREATE OR REPLACE FUNCTION fd.outbox_waiting() RETURNS trigger AS $$
BEGIN
    IF NEW.sent_at IS NULL AND NEW.failed_at IS NULL THEN
        PERFORM pg_notify('fd_outbox_waiting', NEW.conversation_id::text);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER intake_outbox_waiting
    AFTER INSERT ON fd.intake_outbox
    FOR EACH ROW EXECUTE FUNCTION fd.outbox_waiting();
