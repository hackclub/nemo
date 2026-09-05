select
    quality_result_id,
    run_id,
    subject,
    assertion,
    severity,
    status,
    observed,
    expected,
    checked_at
from {{ source('ingest', 'quality_result') }}
