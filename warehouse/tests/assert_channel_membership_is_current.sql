-- The window row must carry the membership Slack returned with it.
-- Before 0049 this came from raw.channel_dim, where it was written by a
-- different job that never revisited a loaded day, so it drifted silently.
select channel_id, window_start, window_end, total_members
from {{ ref('mart_channel_range') }}
where total_members is null
