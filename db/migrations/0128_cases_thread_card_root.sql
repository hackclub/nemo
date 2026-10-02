ALTER TABLE fd.cases
    ADD COLUMN IF NOT EXISTS card_thread_ts text;

CREATE UNIQUE INDEX IF NOT EXISTS cases_one_card_per_thread
    ON fd.cases (card_channel_id, card_thread_ts)
    WHERE card_thread_ts IS NOT NULL;
