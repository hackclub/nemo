CREATE INDEX IF NOT EXISTS ingest_run_started_idx
    ON raw.ingest_run (started_at DESC);

CREATE INDEX IF NOT EXISTS ingest_run_parent_started_idx
    ON raw.ingest_run (started_at DESC)
    WHERE parent_run_id IS NULL AND source = 'nightly_sync';

CREATE INDEX IF NOT EXISTS ingest_run_failed_idx
    ON raw.ingest_run (started_at DESC)
    WHERE status = 'failed' AND parent_run_id IS NOT NULL;

COMMENT ON INDEX raw.ingest_run_started_idx IS
    'Every engine screen orders runs by started_at. Without this the page sorted the whole table on each tab and spent its statement timeout doing it.';

COMMENT ON INDEX raw.ingest_run_parent_started_idx IS
    'The newest nightly_sync parent, read on every engine tab. One row should cost one row to find.';

COMMENT ON INDEX raw.ingest_run_failed_idx IS
    'The fault taxonomy, which groups a month of failed child runs by error_class.';
