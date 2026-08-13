CREATE TABLE fd.decisions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL,
    statement text NOT NULL,
    category_key text,
    reasons text[] NOT NULL DEFAULT '{}',
    state text NOT NULL DEFAULT 'proposed',
    proposed_by text NOT NULL,
    proposed_at timestamptz NOT NULL DEFAULT now(),
    settled_by text,
    settled_at timestamptz,
    retired_by text,
    retired_at timestamptz,
    replaced_by_id bigint REFERENCES fd.decisions(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT decisions_state_known CHECK (state IN ('proposed', 'settled', 'superseded')),
    CONSTRAINT decisions_title_present CHECK (btrim(title) <> ''),
    CONSTRAINT decisions_statement_present CHECK (btrim(statement) <> ''),
    CONSTRAINT decisions_reasons_present CHECK (
        array_position(reasons, '') IS NULL AND array_position(reasons, NULL) IS NULL
    ),
    CONSTRAINT decisions_settled_together CHECK ((settled_at IS NULL) = (settled_by IS NULL)),
    CONSTRAINT decisions_retired_together CHECK ((retired_at IS NULL) = (retired_by IS NULL)),
    CONSTRAINT decisions_proposed_is_unsettled CHECK ((state = 'proposed') = (settled_at IS NULL)),
    CONSTRAINT decisions_superseded_is_retired CHECK (
        (state = 'superseded') = (retired_at IS NOT NULL)
    ),
    CONSTRAINT decisions_replacement_is_another CHECK (
        replaced_by_id IS NULL OR replaced_by_id <> id
    ),
    CONSTRAINT decisions_replacement_only_when_retired CHECK (
        replaced_by_id IS NULL OR state = 'superseded'
    )
);

CREATE UNIQUE INDEX decisions_one_live_title ON fd.decisions (lower(title))
    WHERE state <> 'superseded';

CREATE INDEX decisions_state_idx ON fd.decisions (state, settled_at DESC NULLS LAST);

CREATE INDEX decisions_category_idx ON fd.decisions (category_key)
    WHERE category_key IS NOT NULL;

CREATE INDEX decisions_replaced_by_idx ON fd.decisions (replaced_by_id)
    WHERE replaced_by_id IS NOT NULL;
