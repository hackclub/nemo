ALTER TABLE fd.case_threads
    ADD COLUMN removed_at timestamptz,
    ADD COLUMN removed_by text,
    ADD CONSTRAINT case_threads_removal_complete CHECK ((removed_at IS NULL) = (removed_by IS NULL));
