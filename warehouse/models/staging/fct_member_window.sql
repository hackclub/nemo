{{ config(materialized='table', indexes=[{'columns': ['source', 'user_id']}]) }}

with latest as (
    select window_start, window_end
    from {{ source('raw', 'member_activity_snapshot') }}
    where window_start < window_end
    group by window_start, window_end
    order by window_end desc, window_start asc
    limit 1
)

select
    a.user_id,
    a.window_start,
    a.window_end,
    a.source,
    a.days_active,
    a.days_active_desktop,
    a.days_active_android,
    a.days_active_ios,
    a.days_slack_connect,
    a.messages_posted,
    a.channel_messages_posted,
    a.reactions_added,
    a.files_uploaded,
    a.huddles,
    a.searches,
    a.channels_joined,
    a.last_active_at,
    a.last_active_desktop_at,
    a.last_active_android_at,
    a.last_active_ios_at
from {{ source('raw', 'member_activity_snapshot') }} a
join latest l
    on l.window_start = a.window_start
    and l.window_end = a.window_end
