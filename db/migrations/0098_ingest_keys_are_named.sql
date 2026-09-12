ALTER TABLE raw.sync_cursor
    DROP CONSTRAINT IF EXISTS sync_cursor_window_is_workspace_wide;

ALTER TABLE raw.sync_cursor
    ADD CONSTRAINT sync_cursor_window_is_workspace_wide
    CHECK (window_key IS NULL OR channel_id = '');

COMMENT ON TABLE raw.sync_cursor IS
    'One resume point per source, per channel. Natural key (source, channel_id).';

COMMENT ON COLUMN raw.sync_cursor.channel_id IS
    'The channel this cursor resumes, or the empty string when the source is not channel-scoped. Empty is a real key part, not a missing value.';

COMMENT ON COLUMN raw.sync_cursor.window_key IS
    'Which window the cursor belongs to, for sources that walk one window at a time. Not part of the key: a source holds one window in flight, and a walk that resumes against a different window_key starts over rather than resuming the wrong one.';

COMMENT ON TABLE ingest.slice_coverage IS
    'One row per slice of a source. Natural key (source_key, slice_key), enforced by the unique constraint of the same name; id is a lease handle for the work queue, not an identity.';

COMMENT ON COLUMN ingest.slice_coverage.id IS
    'Surrogate handle, stable across re-claims of the same slice. Never a grain: two rows with different ids and the same (source_key, slice_key) cannot exist.';
