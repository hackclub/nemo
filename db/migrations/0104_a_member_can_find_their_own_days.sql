CREATE INDEX IF NOT EXISTS member_activity_snapshot_mine_idx
    ON raw.member_activity_snapshot (user_id, window_start)
    WHERE window_start = window_end;
