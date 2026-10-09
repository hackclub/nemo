CREATE INDEX IF NOT EXISTS work_item_complete_idx
    ON ingest.work_item ((coalesce(settled_at, updated_at)))
    WHERE state = 'complete';

CREATE INDEX IF NOT EXISTS slice_coverage_run_idx
    ON ingest.slice_coverage (run_id)
    WHERE run_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ingest_step_output_created_idx
    ON raw.ingest_step_output (created_at);
