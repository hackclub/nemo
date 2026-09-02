ALTER TABLE fd.intake_outbox ADD COLUMN IF NOT EXISTS claimed_at timestamptz;

CREATE INDEX IF NOT EXISTS intake_outbox_claim_idx
    ON fd.intake_outbox (requested_at)
    WHERE sent_at IS NULL AND failed_at IS NULL;
