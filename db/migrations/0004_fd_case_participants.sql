CREATE TABLE fd.case_participants (
    case_id bigint NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    role text NOT NULL,
    noted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (case_id, user_id, role),
    CONSTRAINT case_participants_role_check
        CHECK (role IN ('target', 'reporter', 'witness', 'participant'))
);

CREATE INDEX case_participants_user_idx ON fd.case_participants (user_id, role);
