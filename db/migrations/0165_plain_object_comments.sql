COMMENT ON COLUMN fd.intake_messages.body IS
    'Message text as written. Outbound rows no longer store a placeholder for a '
    'wordless message; the attached files carry the content instead.';

COMMENT ON COLUMN fd.intake_messages.ts IS
    'Slack message timestamp. Inbound rows always have one. Outbound rows may be '
    'null, because an upload is not always assigned a timestamp by Slack and the '
    'record of what was sent must not block on it.';

COMMENT ON TABLE fd.intake_outbox IS
    'Outbound messages from the Fire Department to a reporter. Nemo enqueues, the '
    'relay delivers, so neither container depends on the other and a message '
    'written while the other is down stays queued.';

COMMENT ON TABLE fd.thread_guard_strikes IS
    'Members who posted after a thread warning, and whether their Slack sessions '
    'were reset for it. Counted per guard, so strikes on one thread do not carry '
    'over to another.';
