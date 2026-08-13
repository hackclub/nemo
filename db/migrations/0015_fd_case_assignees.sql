CREATE TABLE fd.case_assignees (
    case_id bigint NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by text,
    PRIMARY KEY (case_id, user_id)
);

CREATE INDEX case_assignees_user_idx ON fd.case_assignees (user_id, assigned_at DESC);
