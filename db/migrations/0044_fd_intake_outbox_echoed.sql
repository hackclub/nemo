ALTER TABLE fd.intake_outbox
    ADD COLUMN echoed_at timestamptz,
    ADD COLUMN echoed_ts text,
    ADD COLUMN echoed_as text;

ALTER TABLE fd.intake_outbox ADD CONSTRAINT intake_outbox_echoed_by_somebody
    CHECK (echoed_as IS NULL OR echoed_as IN ('user', 'nemo'));

CREATE INDEX intake_outbox_unechoed_idx
    ON fd.intake_outbox (conversation_id)
    WHERE sent_at IS NOT NULL AND echoed_at IS NULL;
