{% set stale_after_days = 3 %}

select
    max(window_end) as newest_window,
    current_date - max(window_end) as days_behind
from {{ ref('mart_channel_range') }}
having current_date - max(window_end) > {{ stale_after_days }}
    or max(window_end) is null
