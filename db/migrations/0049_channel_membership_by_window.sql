ALTER TABLE raw.channel_activity_snapshot
    ADD COLUMN total_members integer,
    ADD COLUMN full_members integer,
    ADD COLUMN guests integer;

-- dbt owns analytics.dim_channel and everything built on it, and rebuilds all of
-- them on the next transform. Dropping it here is what lets the raw columns go.
DROP VIEW IF EXISTS analytics.dim_channel CASCADE;

ALTER TABLE raw.channel_dim
    DROP COLUMN total_members,
    DROP COLUMN full_members,
    DROP COLUMN guests;
