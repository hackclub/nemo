ALTER TABLE fd.intake_message_files
    ADD COLUMN mirrored_file_id text,
    ADD COLUMN mirrored_at timestamptz,
    ADD CONSTRAINT intake_message_files_mirrored_together CHECK (
        (mirrored_at IS NULL) = (mirrored_file_id IS NULL)
    );

CREATE INDEX intake_message_files_unmirrored_idx
    ON fd.intake_message_files (message_id)
    WHERE mirrored_at IS NULL;
