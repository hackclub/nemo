select
    parent_run_id,
    step_index,
    source,
    output,
    created_at
from {{ source('raw', 'ingest_step_output') }}
