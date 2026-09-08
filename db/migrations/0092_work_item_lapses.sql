ALTER TABLE ingest.work_item
    ADD COLUMN IF NOT EXISTS lapses integer NOT NULL DEFAULT 0;
