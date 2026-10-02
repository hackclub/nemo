CREATE TABLE fd.member_link (
    a_user_id   text        NOT NULL,
    b_user_id   text        NOT NULL,
    score       numeric(8,3) NOT NULL,
    top_signal  text,
    signals     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    first_seen  timestamptz,
    last_seen   timestamptz,
    computed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (a_user_id, b_user_id),
    CONSTRAINT member_link_ordered CHECK (a_user_id < b_user_id),
    CONSTRAINT member_link_score_positive CHECK (score > 0)
);

CREATE INDEX member_link_a_idx ON fd.member_link (a_user_id, score DESC);
CREATE INDEX member_link_b_idx ON fd.member_link (b_user_id, score DESC);
CREATE INDEX member_link_strongest_idx ON fd.member_link (score DESC);

CREATE VIEW fd.member_link_side AS
SELECT a_user_id AS user_id, b_user_id AS other_id, score, top_signal, signals,
       first_seen, last_seen, computed_at
FROM fd.member_link
UNION ALL
SELECT b_user_id, a_user_id, score, top_signal, signals,
       first_seen, last_seen, computed_at
FROM fd.member_link;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.member_link TO pipeline_writer;
        GRANT SELECT ON fd.member_link_side TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.member_link TO rails_app;
        GRANT SELECT ON fd.member_link_side TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_link FROM dbt_owner;
        REVOKE ALL ON fd.member_link_side FROM dbt_owner;
    END IF;
END
$$;
