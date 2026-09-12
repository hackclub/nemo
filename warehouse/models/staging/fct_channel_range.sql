with latest as (
    select window_start, window_end
    from {{ source('raw', 'channel_activity_snapshot') }}
    where source = 'admin_analytics_channel_range'
    group by window_start, window_end
    order by window_end desc, window_start asc
    limit 1
)

select
    a.channel_id,
    a.window_start,
    a.window_end,
    a.messages_posted,
    a.messages_posted_by_members,
    a.members_who_posted,
    a.members_who_viewed,
    a.reactions_added,
    a.members_who_reacted,
    a.huddles_initiated,
    a.total_members,
    a.full_members,
    a.guests,
    a.date_created,
    a.last_message_at
from {{ source('raw', 'channel_activity_snapshot') }} a
join latest l
    on l.window_start = a.window_start
    and l.window_end = a.window_end
where a.source = 'admin_analytics_channel_range'
