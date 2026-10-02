select
    a.channel_id,
    c.name,
    c.visibility,
    a.total_members,
    a.full_members,
    a.guests,
    a.window_start,
    a.window_end,
    a.messages_posted,
    a.messages_posted_by_members,
    a.members_who_posted,
    a.members_who_viewed,
    a.reactions_added,
    a.members_who_reacted,
    a.huddles_initiated,
    a.date_created,
    a.last_message_at,
    'v2' as metric_version
from {{ ref('fct_channel_range') }} a
left join {{ ref('dim_channel') }} c using (channel_id)
