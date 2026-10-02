UPDATE fd.intake_messages
SET body = NULL
WHERE direction = 'outbound'
  AND body = 'they sent no words, only what is attached';

COMMENT ON COLUMN fd.intake_messages.body IS
    'What was written, as written. Outbound rows once stored the reporter-facing placeholder for a wordless message; they hold nothing now, and the files beside them say what went.';
