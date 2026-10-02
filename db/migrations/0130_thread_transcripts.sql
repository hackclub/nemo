CREATE TABLE fd.thread_transcripts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guard_id bigint REFERENCES fd.thread_guards(id) ON DELETE SET NULL,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    body text NOT NULL,
    kept_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX thread_transcripts_at
    ON fd.thread_transcripts (channel_id, thread_ts, kept_at DESC);

INSERT INTO fd.thread_transcripts (guard_id, channel_id, thread_ts, body, kept_at)
SELECT g.id, g.channel_id, g.thread_ts, convert_from(b.body, 'UTF8'),
       coalesce(g.finished_at, g.created_at)
FROM fd.thread_guards g
JOIN fd.intake_file_blobs b ON b.sha256 = g.transcript_sha
WHERE g.transcript_sha IS NOT NULL;
