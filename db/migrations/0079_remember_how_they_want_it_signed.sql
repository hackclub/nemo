ALTER TABLE fd.intake_conversations ADD COLUMN IF NOT EXISTS consent_choice text;

DO $$
BEGIN
    ALTER TABLE fd.intake_conversations
        ADD CONSTRAINT intake_conversations_consent_choice_check
        CHECK (consent_choice IS NULL OR consent_choice IN ('anonymous', 'named'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;
