ALTER TABLE raw.channel_activity_snapshot
    ADD COLUMN date_created timestamptz,
    ADD COLUMN last_message_at timestamptz;
