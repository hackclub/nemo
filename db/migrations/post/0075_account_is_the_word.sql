ALTER TABLE IF EXISTS app.staff RENAME TO account;

DO $$
BEGIN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON app.account TO rails_app';
    EXECUTE 'GRANT SELECT ON app.account TO pipeline_writer';
EXCEPTION
    WHEN undefined_object OR insufficient_privilege OR undefined_table THEN NULL;
END
$$;
