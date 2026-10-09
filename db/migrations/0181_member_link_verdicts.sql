CREATE TABLE fd.member_link_verdict (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    a_user_id   text        NOT NULL,
    b_user_id   text        NOT NULL,
    verdict     text        NOT NULL,
    decided_by  text        NOT NULL,
    decided_at  timestamptz NOT NULL DEFAULT now(),
    note        text,
    CONSTRAINT member_link_verdict_one_per_pair UNIQUE (a_user_id, b_user_id),
    CONSTRAINT member_link_verdict_ordered CHECK (a_user_id < b_user_id),
    CONSTRAINT member_link_verdict_known
        CHECK (verdict IN ('same_person', 'different_people', 'household', 'staff_test')),
    CONSTRAINT member_link_verdict_decided_by_present CHECK (btrim(decided_by) <> ''),
    CONSTRAINT member_link_verdict_note_present CHECK (note IS NULL OR btrim(note) <> '')
);

CREATE INDEX member_link_verdict_b_idx ON fd.member_link_verdict (b_user_id);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE ON fd.member_link_verdict TO pipeline_writer;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA fd TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT, INSERT, UPDATE ON fd.member_link_verdict TO rails_app;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA fd TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_link_verdict FROM dbt_owner;
    END IF;
END
$$;
