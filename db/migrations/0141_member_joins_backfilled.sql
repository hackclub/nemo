ALTER TABLE fd.member_joins
    DROP CONSTRAINT member_joins_source_known;

ALTER TABLE fd.member_joins
    ADD CONSTRAINT member_joins_source_known
    CHECK (source IN ('team_join', 'by_hand', 'cohort'));

DO $$
BEGIN
    IF to_regclass('analytics.dim_member') IS NULL THEN
        RAISE NOTICE 'analytics.dim_member is not built yet, nothing to backfill';
        RETURN;
    END IF;

    INSERT INTO fd.member_joins (user_id, joined_at, source)
    SELECT d.user_id, d.cohort_at, 'cohort'
    FROM analytics.dim_member d
    JOIN fd.member m ON m.user_id = d.user_id
    WHERE d.cohort_at IS NOT NULL
    ON CONFLICT (user_id) DO NOTHING;
END
$$;
