CREATE TABLE fd.cases (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subject_user_id text,
    category_key text,
    opened_by text NOT NULL,
    opened_at timestamptz NOT NULL DEFAULT now(),
    claimed_by text,
    claimed_at timestamptz,
    resolved_at timestamptz,
    resolution text CHECK (resolution IS NULL OR resolution IN
        ('action_taken', 'no_action', 'duplicate', 'not_conduct')),
    member_note text,
    subject_context jsonb,
    source_app text NOT NULL DEFAULT 'fire_engine',
    external_ref text UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cases_claimed_together CHECK ((claimed_at IS NULL) = (claimed_by IS NULL)),
    CONSTRAINT cases_resolved_together CHECK ((resolved_at IS NULL) = (resolution IS NULL))
);

CREATE INDEX cases_subject_idx ON fd.cases (subject_user_id)
    WHERE subject_user_id IS NOT NULL;

CREATE INDEX cases_open_idx ON fd.cases (opened_at)
    WHERE resolved_at IS NULL;
