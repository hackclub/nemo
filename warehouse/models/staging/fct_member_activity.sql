select
    user_id,
    window_start,
    window_end,
    source,
    days_active,
    days_active_desktop,
    days_active_android,
    days_active_ios,
    days_slack_connect,
    messages_posted,
    channel_messages_posted,
    reactions_added,
    files_uploaded,
    huddles,
    searches,
    channels_joined,
    last_active_at,
    last_active_desktop_at,
    last_active_android_at,
    last_active_ios_at
from {{ source('raw', 'member_activity_snapshot') }} a
where window_start = window_end
  and exists (
      select 1
      from {{ ref('fct_analytics_day') }} d
      where d.source = 'member_day'
        and d.ds = a.window_start
        and d.loaded
  )
