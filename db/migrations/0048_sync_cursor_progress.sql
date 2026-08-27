ALTER TABLE raw.sync_cursor
    ADD COLUMN IF NOT EXISTS rows_seen integer NOT NULL DEFAULT 0;

ALTER TABLE raw.sync_cursor
    ADD COLUMN IF NOT EXISTS window_key text;
