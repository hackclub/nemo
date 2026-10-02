CREATE INDEX work_item_dead_idx ON ingest.work_item (work_kind, next_attempt_at)
    WHERE state = 'dead';
