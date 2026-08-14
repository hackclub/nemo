CREATE TABLE fd.intake_files (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slack_file_id text UNIQUE,
    name text,
    title text,
    mimetype text,
    filetype text,
    mode text,
    size_bytes bigint,
    original_w integer,
    original_h integer,
    is_external boolean NOT NULL DEFAULT false,
    external_type text,
    external_url text,
    permalink text,
    url_private text,
    uploaded_by text,
    is_tombstoned boolean NOT NULL DEFAULT false,
    is_hidden_by_limit boolean NOT NULL DEFAULT false,
    fetch_state text NOT NULL DEFAULT 'pending' CHECK (fetch_state IN (
        'pending', 'stored', 'skipped', 'refused', 'gone', 'too_large', 'failed'
    )),
    fetch_error text,
    fetch_attempts integer NOT NULL DEFAULT 0,
    sha256 text,
    stored_key text,
    stored_bytes bigint,
    fetched_at timestamptz,
    created_at timestamptz,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    purged_at timestamptz,
    purged_by text,
    CONSTRAINT intake_files_stored_has_bytes CHECK (
        fetch_state <> 'stored' OR (stored_key IS NOT NULL AND sha256 IS NOT NULL)
    ),
    CONSTRAINT intake_files_failed_has_reason CHECK (
        fetch_state NOT IN ('refused', 'failed', 'too_large') OR fetch_error IS NOT NULL
    ),
    CONSTRAINT intake_files_purged_together CHECK ((purged_at IS NULL) = (purged_by IS NULL)),
    CONSTRAINT intake_files_purged_has_no_copy CHECK (purged_at IS NULL OR stored_key IS NULL)
);

CREATE INDEX intake_files_sha_idx ON fd.intake_files (sha256)
    WHERE sha256 IS NOT NULL;

CREATE INDEX intake_files_pending_idx ON fd.intake_files (first_seen_at)
    WHERE fetch_state = 'pending';

CREATE TABLE fd.intake_message_files (
    message_id bigint NOT NULL REFERENCES fd.intake_messages(id) ON DELETE CASCADE,
    file_id bigint NOT NULL REFERENCES fd.intake_files(id) ON DELETE CASCADE,
    seq integer NOT NULL DEFAULT 0,
    shared_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, file_id)
);

CREATE INDEX intake_message_files_file_idx ON fd.intake_message_files (file_id);

DO $$
DECLARE
    name text;
BEGIN
    FOREACH name IN ARRAY ARRAY['fd.intake_files', 'fd.intake_message_files']
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
