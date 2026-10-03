ALTER TABLE fd.case_chat RENAME COLUMN said_at TO posted_at;

ALTER TABLE fd.slowmode_clock RENAME COLUMN said_at TO posted_at;

ALTER TABLE fd.channel_guard_events RENAME COLUMN said TO message_text;

ALTER TABLE fd.thread_guards RENAME COLUMN note_said TO note_rich;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'fd.case_chat'::regclass AND conname = 'case_chat_said_at_not_null'
    ) THEN
        ALTER TABLE fd.case_chat
            RENAME CONSTRAINT case_chat_said_at_not_null TO case_chat_posted_at_not_null;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'fd.slowmode_clock'::regclass
          AND conname = 'slowmode_clock_said_at_not_null'
    ) THEN
        ALTER TABLE fd.slowmode_clock
            RENAME CONSTRAINT slowmode_clock_said_at_not_null TO slowmode_clock_posted_at_not_null;
    END IF;
END $$;
