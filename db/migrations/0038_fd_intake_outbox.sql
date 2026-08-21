CREATE TABLE fd.intake_outbox (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id bigint NOT NULL REFERENCES fd.intake_conversations(id) ON DELETE CASCADE,
    kind text NOT NULL,
    body text NOT NULL,
    mode text NOT NULL DEFAULT 'body',
    requested_by text NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    message_id bigint REFERENCES fd.intake_messages(id) ON DELETE SET NULL,
    attempts integer NOT NULL DEFAULT 0,
    failed_at timestamptz,
    error text,
    source_app text NOT NULL DEFAULT 'fire_engine',
    CONSTRAINT intake_outbox_kind_check CHECK (kind IN ('reply', 'outcome')),
    CONSTRAINT intake_outbox_mode_check CHECK (mode IN ('body', 'signed')),
    CONSTRAINT intake_outbox_failed_together CHECK ((failed_at IS NULL) = (error IS NULL)),
    CONSTRAINT intake_outbox_sent_is_not_failed CHECK (sent_at IS NULL OR failed_at IS NULL)
);

CREATE INDEX intake_outbox_waiting_idx
    ON fd.intake_outbox (requested_at)
    WHERE sent_at IS NULL AND failed_at IS NULL;

CREATE INDEX intake_outbox_conversation_idx
    ON fd.intake_outbox (conversation_id, requested_at);
