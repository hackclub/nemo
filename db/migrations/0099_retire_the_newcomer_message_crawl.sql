DROP TABLE IF EXISTS raw.member_channel_message;

ALTER TABLE raw.member_channel_walk
    DROP CONSTRAINT IF EXISTS member_channel_walk_pages;

ALTER TABLE raw.member_channel_walk
    DROP COLUMN IF EXISTS messages_searched_at,
    DROP COLUMN IF EXISTS pages,
    DROP COLUMN IF EXISTS truncated;

DELETE FROM ingest.work_item WHERE work_kind = 'member_channels';

COMMENT ON TABLE raw.member_channel_walk IS
    'One row per newcomer, recording when their channel membership was last read. The message crawl that shared this ledger was retired once fct_member_channel moved to the archive.';
