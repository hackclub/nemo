ALTER TABLE raw.worker_heartbeat
    ADD COLUMN IF NOT EXISTS worker_boot uuid;
