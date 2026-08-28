select channel_id, window_start, window_end, total_members
from {{ ref('mart_channel_range') }}
where total_members is null
