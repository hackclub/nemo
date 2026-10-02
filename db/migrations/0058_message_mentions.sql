ALTER TABLE raw.message
    ADD COLUMN IF NOT EXISTS mentioned_ids text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS message_mentioned_idx ON raw.message USING gin (mentioned_ids);
