CREATE OR REPLACE FUNCTION fd.app_setting_changed() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('fd_app_setting', COALESCE(NEW.key, OLD.key));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS app_settings_changed ON fd.app_settings;

CREATE TRIGGER app_settings_changed
    AFTER INSERT OR UPDATE OF value OR DELETE ON fd.app_settings
    FOR EACH ROW EXECUTE FUNCTION fd.app_setting_changed();
