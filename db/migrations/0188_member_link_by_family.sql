ALTER TABLE fd.member_link
    ADD COLUMN IF NOT EXISTS top_family text,
    ADD COLUMN IF NOT EXISTS families jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS label text;

ALTER TABLE fd.member_link
    ADD CONSTRAINT member_link_label_known
    CHECK (label IN ('household', 'classroom', 'staff_test'));

DROP VIEW IF EXISTS fd.member_link_side;

CREATE VIEW fd.member_link_side AS
SELECT a_user_id AS user_id, b_user_id AS other_id, score, top_signal, signals,
       first_seen, last_seen, computed_at, top_family, families, label
FROM fd.member_link
UNION ALL
SELECT b_user_id, a_user_id, score, top_signal, signals,
       first_seen, last_seen, computed_at, top_family, families, label
FROM fd.member_link;

DROP TABLE IF EXISTS fd.member_link_v2;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT ON fd.member_link_side TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.member_link_side TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_link_side FROM dbt_owner;
    END IF;
END
$$;
