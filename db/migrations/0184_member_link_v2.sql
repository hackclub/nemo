CREATE TABLE fd.member_link_v2 (
    a_user_id   text         NOT NULL,
    b_user_id   text         NOT NULL,
    score       numeric(8,3) NOT NULL,
    top_family  text,
    families    jsonb        NOT NULL DEFAULT '{}'::jsonb,
    signals     jsonb        NOT NULL DEFAULT '{}'::jsonb,
    first_seen  timestamptz,
    last_seen   timestamptz,
    computed_at timestamptz  NOT NULL DEFAULT now(),
    PRIMARY KEY (a_user_id, b_user_id),
    CONSTRAINT member_link_v2_ordered CHECK (a_user_id < b_user_id),
    CONSTRAINT member_link_v2_score_positive CHECK (score > 0)
);

CREATE INDEX member_link_v2_a_idx ON fd.member_link_v2 (a_user_id, score DESC);
CREATE INDEX member_link_v2_b_idx ON fd.member_link_v2 (b_user_id, score DESC);
CREATE INDEX member_link_v2_strongest_idx ON fd.member_link_v2 (score DESC);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.member_link_v2 TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.member_link_v2 TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_link_v2 FROM dbt_owner;
    END IF;
END
$$;
