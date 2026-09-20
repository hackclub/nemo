ALTER TABLE fd.intake_messages ALTER COLUMN ts DROP NOT NULL;

ALTER TABLE fd.intake_messages
    ADD CONSTRAINT intake_messages_theirs_is_named CHECK (
        ts IS NOT NULL OR direction = 'outbound'
    );

COMMENT ON COLUMN fd.intake_messages.ts IS
    'Slack''s name for the message. Theirs always has one. Ours can lack it, because an upload is not always named by Slack and the record of what we sent must not wait on that.';
