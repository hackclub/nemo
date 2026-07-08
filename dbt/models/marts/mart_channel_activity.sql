select
    c.channel_id,
    c.name,
    c.visibility,
    c.total_members,
    a.window_start,
    a.window_end,
    a.messages_posted,
    a.messages_posted_by_members,
    a.members_who_posted,
    a.members_who_viewed,
    a.reactions_added,
    a.huddles_initiated,
    'v1' as metric_version
from {{ ref('fct_channel_activity') }} a
join {{ ref('dim_channel') }} c using (channel_id)
