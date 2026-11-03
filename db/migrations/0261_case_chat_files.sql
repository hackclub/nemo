CREATE TABLE fd.case_chat_files (
    chat_id bigint NOT NULL REFERENCES fd.case_chat(id) ON DELETE CASCADE,
    file_id bigint NOT NULL REFERENCES fd.intake_files(id) ON DELETE CASCADE,
    seq integer NOT NULL DEFAULT 0,
    shared_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (chat_id, file_id)
);

CREATE INDEX case_chat_files_file_idx ON fd.case_chat_files (file_id);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.case_chat_files FROM dbt_owner;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        REVOKE INSERT, UPDATE, DELETE ON fd.case_chat_files FROM rails_app;
    END IF;
END
$$;
