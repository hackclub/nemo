ALTER TABLE raw.ingest_run
    ADD COLUMN IF NOT EXISTS source_key text,
    ADD COLUMN IF NOT EXISTS logical_date date,
    ADD COLUMN IF NOT EXISTS worker text,
    ADD COLUMN IF NOT EXISTS worker_boot uuid,
    ADD COLUMN IF NOT EXISTS stream_key text,
    ADD COLUMN IF NOT EXISTS slice_key text,
    ADD COLUMN IF NOT EXISTS attempt smallint NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS parser_version smallint NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS error_class text,
    ADD COLUMN IF NOT EXISTS error_detail text,
    ADD COLUMN IF NOT EXISTS http_status smallint,
    ADD COLUMN IF NOT EXISTS slack_error text,
    ADD COLUMN IF NOT EXISTS had_fault_body boolean,
    ADD COLUMN IF NOT EXISTS pages integer,
    ADD COLUMN IF NOT EXISTS rate_limited_ms integer,
    ADD COLUMN IF NOT EXISTS deadline_at timestamptz,
    ADD COLUMN IF NOT EXISTS suspected_dead_at timestamptz;

UPDATE raw.ingest_run
SET source_key = CASE
        WHEN source = 'admin_analytics_api:member' THEN 'member_days'
        WHEN source = 'admin_analytics_api:public_channel' THEN 'channel_days'
        WHEN source = 'admin_analytics_member_range' THEN 'member_range'
        WHEN source = 'admin_analytics_channel_range' THEN 'channel_range'
        WHEN source = 'admin_analytics_channel_span' THEN 'channel_span'
        WHEN source = 'admin_analytics_channel_month' THEN 'channel_month'
        WHEN source = 'conversations_history' THEN 'channel_history'
        WHEN source = 'channel_info_names' THEN 'channel_names'
        WHEN source = 'autojoin' THEN 'channel_roster'
        ELSE split_part(source, ':', 1)
    END,
    logical_date = (started_at AT TIME ZONE 'UTC')::date
WHERE source_key IS NULL;

ALTER TABLE raw.ingest_run
    ADD CONSTRAINT ingest_run_status_ck CHECK
        (status IN ('running', 'ok', 'failed', 'skipped', 'partial', 'cancelled', 'abandoned'))
    NOT VALID;

CREATE INDEX IF NOT EXISTS ingest_run_source_status_idx
    ON raw.ingest_run (source_key, status, finished_at DESC);
CREATE INDEX IF NOT EXISTS ingest_run_night_idx
    ON raw.ingest_run (logical_date, source_key);
CREATE INDEX IF NOT EXISTS ingest_run_running_worker_idx
    ON raw.ingest_run (worker, worker_boot) WHERE status = 'running';
