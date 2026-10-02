ALTER TABLE fd.case_reports
    ADD COLUMN IF NOT EXISTS forwarded_channel_id text;
