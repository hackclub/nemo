with newest as (
    select max(window_end) as window_end from {{ ref('mart_channel_range') }}
)
select r.channel_id
from {{ ref('mart_channel_range') }} r
cross join newest n
where r.window_end <> n.window_end
