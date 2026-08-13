ALTER TABLE fd.decision_threads
    ADD COLUMN kind text NOT NULL DEFAULT 'internal',
    ADD CONSTRAINT decision_threads_kind_known CHECK (kind IN ('internal', 'reference'));

CREATE INDEX decision_threads_kind_idx ON fd.decision_threads (decision_id, kind);
