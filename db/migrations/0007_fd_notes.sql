CREATE TABLE fd.notes (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id bigint REFERENCES fd.cases(id) ON DELETE CASCADE,
    subject_user_id text,
    body text NOT NULL,
    author text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    deleted_by text,
    CONSTRAINT notes_target_present CHECK (
        case_id IS NOT NULL OR subject_user_id IS NOT NULL
    ),
    CONSTRAINT notes_deleted_together CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL)
    )
);

CREATE INDEX notes_case_idx ON fd.notes (case_id, created_at DESC)
    WHERE case_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX notes_subject_idx ON fd.notes (subject_user_id, created_at DESC)
    WHERE subject_user_id IS NOT NULL AND deleted_at IS NULL;
