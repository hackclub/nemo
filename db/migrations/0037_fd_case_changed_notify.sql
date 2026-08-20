CREATE OR REPLACE FUNCTION fd.case_changed() RETURNS trigger AS $$
DECLARE
    touched bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF TG_TABLE_NAME = 'cases' THEN
            touched := OLD.id;
        ELSE
            touched := OLD.case_id;
        END IF;
    ELSE
        IF TG_TABLE_NAME = 'cases' THEN
            touched := NEW.id;
        ELSE
            touched := NEW.case_id;
        END IF;
    END IF;

    IF touched IS NOT NULL THEN
        PERFORM pg_notify('fd_case_changed', touched::text);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cases_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.cases
    FOR EACH ROW EXECUTE FUNCTION fd.case_changed();

CREATE TRIGGER case_assignees_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.case_assignees
    FOR EACH ROW EXECUTE FUNCTION fd.case_changed();

CREATE TRIGGER case_participants_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.case_participants
    FOR EACH ROW EXECUTE FUNCTION fd.case_changed();

CREATE TRIGGER case_reports_changed
    AFTER INSERT OR UPDATE OF is_anonymous, reporter_user_id, body, closed_at
    ON fd.case_reports
    FOR EACH ROW EXECUTE FUNCTION fd.case_changed();
