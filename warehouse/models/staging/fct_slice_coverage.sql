select
    id as slice_coverage_id,
    source_key,
    slice_key,
    slice_start,
    slice_end,
    state,
    expected,
    landed,
    case
        when expected is null or expected = 0 then null
        else round(landed::numeric / expected, 4)
    end as landed_ratio,
    run_id,
    worker,
    attempts,
    lease_until,
    lease_until is not null and lease_until > now() as leased,
    note,
    claimed_at,
    settled_at,
    updated_at
from {{ source('ingest', 'slice_coverage') }}
