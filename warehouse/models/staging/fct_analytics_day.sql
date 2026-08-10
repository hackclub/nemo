select
    source,
    ds,
    loaded,
    rows_in,
    unavailable,
    reason,
    updated_at
from {{ source('raw', 'analytics_day') }}
