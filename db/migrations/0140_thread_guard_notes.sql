ALTER TABLE fd.thread_guards
    ADD COLUMN note_said jsonb,
    ADD COLUMN note_text text,
    ADD COLUMN note_ts text,
    ADD COLUMN note_posted_at timestamptz;

ALTER TABLE fd.thread_guards
    ADD CONSTRAINT thread_guards_note_is_a_destroy
        CHECK (note_said IS NULL OR kind = 'destroy'),
    ADD CONSTRAINT thread_guards_note_has_words
        CHECK ((note_said IS NULL) = (note_text IS NULL)),
    ADD CONSTRAINT thread_guards_note_posted_together
        CHECK ((note_ts IS NULL) = (note_posted_at IS NULL));
