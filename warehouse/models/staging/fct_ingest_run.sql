select
    id,
    parent_run_id,
    source,
    source_key,
    logical_date,
    worker,
    worker_boot,
    stream_key,
    slice_key,
    attempt,
    parser_version,
    step_index,
    step_total,
    status,
    started_at,
    finished_at,
    case
        when status = 'abandoned' then null
        else coalesce(finished_at, clock_timestamp()) - started_at
    end as elapsed,
    rows_in,
    rows_rejected,
    total_expected,
    case
        when total_expected > 0 and rows_in is not null
        then least(round(rows_in::numeric / total_expected, 4), 1.0)
    end as progress_share,
    error_class,
    error_detail,
    http_status,
    slack_error,
    had_fault_body,
    pages,
    rate_limited_ms,
    deadline_at,
    suspected_dead_at,
    'v2' as metric_version
from {{ source('raw', 'ingest_run') }}
