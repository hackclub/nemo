CREATE TABLE fd.case_citations (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id bigint NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    thread_message_id bigint NOT NULL
        REFERENCES fd.thread_messages(id) ON DELETE RESTRICT,
    flagged_by text NOT NULL,
    flagged_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (case_id, thread_message_id)
);

CREATE INDEX case_citations_case_idx ON fd.case_citations (case_id, flagged_at);
