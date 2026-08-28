ALTER TABLE raw.channel_activity_snapshot
    ADD COLUMN total_members integer,
    ADD COLUMN full_members integer,
    ADD COLUMN guests integer;

DROP VIEW IF EXISTS analytics.dim_channel CASCADE;

ALTER TABLE raw.channel_dim
    DROP COLUMN total_members,
    DROP COLUMN full_members,
    DROP COLUMN guests;
