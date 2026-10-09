CREATE OR REPLACE FUNCTION fd.member_link_changed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_notify('fd_member_link', '*');
    IF current_setting('fd.quiet_links', true) IS NOT DISTINCT FROM 'on' THEN
        RETURN NULL;
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM pg_notify('fd_member_link', OLD.a_user_id);
        PERFORM pg_notify('fd_member_link', OLD.b_user_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM pg_notify('fd_member_link', NEW.a_user_id);
        PERFORM pg_notify('fd_member_link', NEW.b_user_id);
    END IF;
    RETURN NULL;
END
$$;

CREATE TRIGGER member_link_changed
    AFTER INSERT OR UPDATE OR DELETE ON fd.member_link
    FOR EACH ROW EXECUTE FUNCTION fd.member_link_changed();
