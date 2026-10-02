ALTER TABLE fd.cases
    ADD COLUMN IF NOT EXISTS card_channel_id text,
    ADD COLUMN IF NOT EXISTS card_ts text,
    ADD COLUMN IF NOT EXISTS card_digest text;
