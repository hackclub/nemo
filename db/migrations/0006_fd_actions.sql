CREATE TABLE fd.actions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id bigint NOT NULL REFERENCES fd.cases(id),
    type_key text NOT NULL,
    target_user_id text NOT NULL,
    decided_by text NOT NULL,
    performed_by text NOT NULL,
    performed_at timestamptz NOT NULL DEFAULT now(),
    source_app text NOT NULL DEFAULT 'fire_engine',
    expires_at timestamptz,
    reversed_at timestamptz,
    reversed_by text,
    reversal_reason text,
    ladder_version_id bigint,
    subject_context jsonb,
    details jsonb NOT NULL DEFAULT '{}',
    external_ref text UNIQUE,
    CONSTRAINT actions_reversed_together CHECK ((reversed_at IS NULL) = (reversed_by IS NULL))
);

CREATE INDEX actions_case_idx ON fd.actions (case_id);

CREATE INDEX actions_target_idx ON fd.actions (target_user_id, performed_at DESC);

CREATE INDEX actions_expiring_idx ON fd.actions (expires_at)
    WHERE expires_at IS NOT NULL AND reversed_at IS NULL;
