CREATE TABLE fd.case_reports (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id bigint NOT NULL REFERENCES fd.cases(id) ON DELETE CASCADE,
    reporter_user_id text,
    is_anonymous boolean NOT NULL DEFAULT true,
    body text,
    received_at timestamptz NOT NULL DEFAULT now(),
    dm_channel_id text,
    dm_ts text,
    forwarded_ts text,
    first_replied_at timestamptz,
    closed_at timestamptz,
    source_app text NOT NULL,
    external_ref text UNIQUE,
    CONSTRAINT case_reports_anonymous_is_blank CHECK (
        NOT is_anonymous OR (reporter_user_id IS NULL AND dm_channel_id IS NULL)
    ),
    CONSTRAINT case_reports_identified_has_reporter CHECK (
        is_anonymous OR reporter_user_id IS NOT NULL
    )
);

CREATE INDEX case_reports_case_idx ON fd.case_reports (case_id);
