ALTER TABLE raw.event_delivery
    ADD COLUMN IF NOT EXISTS shape jsonb,
    ADD COLUMN IF NOT EXISTS projected_at timestamptz;

CREATE INDEX IF NOT EXISTS event_delivery_unprojected_idx
    ON raw.event_delivery (received_at)
    WHERE projected_at IS NULL;
