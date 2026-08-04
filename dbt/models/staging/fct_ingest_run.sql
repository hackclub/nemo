select
    id,
    parent_run_id,
    source,
    step_index,
    step_total,
    status,
    started_at,
    finished_at,
    coalesce(finished_at, clock_timestamp()) - started_at as elapsed,
    rows_in,
    rows_rejected,
    total_expected,
    case
        when total_expected > 0 and rows_in is not null
        then least(round(rows_in::numeric / total_expected, 4), 1.0)
    end as progress_share,
    'v1' as metric_version
from {{ source('raw', 'ingest_run') }}
