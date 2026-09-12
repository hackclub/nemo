DELETE FROM raw.top_posters_snapshot t
WHERE  t.ctid NOT IN (
    SELECT DISTINCT ON (date_trunc('month', window_start::timestamp), user_id) ctid
    FROM   raw.top_posters_snapshot
    ORDER  BY date_trunc('month', window_start::timestamp), user_id,
              window_end DESC, window_start ASC, pulled_at DESC
);

ALTER TABLE raw.top_posters_snapshot
    ADD COLUMN IF NOT EXISTS month date
    GENERATED ALWAYS AS (date_trunc('month', window_start::timestamp)::date) STORED;

ALTER TABLE raw.top_posters_snapshot
    DROP CONSTRAINT IF EXISTS top_posters_snapshot_pkey;

ALTER TABLE raw.top_posters_snapshot
    ADD CONSTRAINT top_posters_snapshot_pkey PRIMARY KEY (month, user_id);

COMMENT ON TABLE raw.top_posters_snapshot IS
    'One row per member per calendar month. Natural key (month, user_id).';

COMMENT ON COLUMN raw.top_posters_snapshot.month IS
    'The calendar month this row measures, derived from window_start. The key, because it is the only part of the window that cannot move.';

COMMENT ON COLUMN raw.top_posters_snapshot.window_start IS
    'First day actually measured: the month start, clamped forward to the start of Slack''s available range. It moves as that range rolls, so it is not part of the key.';

COMMENT ON COLUMN raw.top_posters_snapshot.window_end IS
    'Last day actually measured: the month end, clamped back to the end of Slack''s available range. It grows while the month is still open, which is what makes a month eligible for a re-pull.';
