CREATE OR REPLACE FUNCTION fd.intake_file_kept() RETURNS trigger AS $$
DECLARE
    touched bigint;
BEGIN
    IF NEW.fetch_state <> 'stored' OR OLD.fetch_state = 'stored' THEN
        RETURN NULL;
    END IF;

    FOR touched IN
        SELECT DISTINCT r.case_id
        FROM fd.intake_message_files mf
        JOIN fd.intake_messages m ON m.id = mf.message_id
        JOIN fd.intake_conversations c ON c.id = m.conversation_id
        JOIN fd.case_reports r ON r.id = c.report_id
        WHERE mf.file_id = NEW.id
    LOOP
        PERFORM pg_notify('fd_conversation_changed', touched::text);
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER intake_files_kept
    AFTER UPDATE OF fetch_state ON fd.intake_files
    FOR EACH ROW EXECUTE FUNCTION fd.intake_file_kept();

COMMENT ON FUNCTION fd.intake_file_kept() IS
    'A file arrives pending and is fetched a moment later. Without this the card and the case thread would keep saying it was never kept.';

CREATE INDEX IF NOT EXISTS intake_files_stored_idx ON fd.intake_files (id)
    WHERE fetch_state = 'stored';
