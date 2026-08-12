ALTER TABLE fd.case_threads
    ADD COLUMN kind text NOT NULL DEFAULT 'evidence',
    ADD CONSTRAINT case_threads_kind_check CHECK (kind IN ('evidence', 'internal')),
    ADD CONSTRAINT case_threads_primary_is_evidence CHECK (
        NOT is_primary OR kind = 'evidence'
    );

DROP INDEX fd.case_threads_thread_idx;

CREATE INDEX case_threads_thread_idx ON fd.case_threads (channel_id, thread_ts)
    WHERE kind = 'evidence';
