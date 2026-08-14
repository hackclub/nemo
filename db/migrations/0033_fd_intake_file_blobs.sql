CREATE TABLE fd.intake_file_blobs (
    sha256 text PRIMARY KEY,
    body bytea NOT NULL,
    size_bytes bigint NOT NULL,
    mimetype text,
    stored_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT intake_file_blobs_size_is_honest CHECK (size_bytes = length(body))
);

ALTER TABLE fd.intake_files
    ADD CONSTRAINT intake_files_stored_key_fkey
    FOREIGN KEY (stored_key) REFERENCES fd.intake_file_blobs(sha256) ON DELETE RESTRICT;

ALTER TABLE fd.intake_files DROP CONSTRAINT intake_files_fetch_state_check;

ALTER TABLE fd.intake_files
    ADD CONSTRAINT intake_files_fetch_state_check CHECK (fetch_state IN (
        'pending', 'stored', 'skipped', 'refused', 'gone', 'too_large', 'failed', 'purged'
    ));

ALTER TABLE fd.intake_files
    ADD CONSTRAINT intake_files_purged_is_marked CHECK (
        (fetch_state = 'purged') = (purged_at IS NOT NULL)
    );

DO $$
DECLARE
    name text;
BEGIN
    FOREACH name IN ARRAY ARRAY['fd.intake_file_blobs']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
            EXECUTE format('REVOKE ALL ON %s FROM dbt_owner', name);
        END IF;

        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
            EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %s FROM rails_app', name);
        END IF;
    END LOOP;
END
$$;
