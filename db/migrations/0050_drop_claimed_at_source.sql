DROP VIEW IF EXISTS analytics.dim_member CASCADE;

ALTER TABLE raw.member_dim DROP COLUMN claimed_at_source;
