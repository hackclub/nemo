ALTER TABLE fd.case_chat RENAME COLUMN said_at TO posted_at;

ALTER TABLE fd.slowmode_clock RENAME COLUMN said_at TO posted_at;

ALTER TABLE fd.channel_guard_events RENAME COLUMN said TO message_text;

ALTER TABLE fd.thread_guards RENAME COLUMN note_said TO note_rich;

ALTER TABLE fd.case_chat
    RENAME CONSTRAINT case_chat_said_at_not_null TO case_chat_posted_at_not_null;

ALTER TABLE fd.slowmode_clock
    RENAME CONSTRAINT slowmode_clock_said_at_not_null TO slowmode_clock_posted_at_not_null;
