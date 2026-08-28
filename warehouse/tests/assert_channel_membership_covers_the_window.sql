-- Every channel the dashboard can list must have a row in the newest window.
-- A channel that falls out of the walk should read n/a, not carry a number
-- from a window nobody can name.
with newest as (
    select max(window_end) as window_end from {{ ref('mart_channel_range') }}
)
select r.channel_id
from {{ ref('mart_channel_range') }} r
cross join newest n
where r.window_end <> n.window_end
