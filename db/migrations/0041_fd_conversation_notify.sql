CREATE OR REPLACE FUNCTION fd.conversation_touched() RETURNS trigger AS $$
DECLARE
    convo bigint;
    touched bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        convo := OLD.conversation_id;
    ELSE
        convo := NEW.conversation_id;
    END IF;

    SELECT r.case_id INTO touched
    FROM fd.intake_conversations c
    JOIN fd.case_reports r ON r.id = c.report_id
    WHERE c.id = convo;

    IF touched IS NOT NULL THEN
        PERFORM pg_notify('fd_conversation_changed', touched::text);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER intake_messages_touched
    AFTER INSERT OR UPDATE OF body, edited_at, deleted_at ON fd.intake_messages
    FOR EACH ROW EXECUTE FUNCTION fd.conversation_touched();

CREATE TRIGGER intake_outbox_touched
    AFTER INSERT OR UPDATE OF sent_at, failed_at, error ON fd.intake_outbox
    FOR EACH ROW EXECUTE FUNCTION fd.conversation_touched();
