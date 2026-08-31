select
    channel_id,
    window_start,
    window_end,
    messages_posted,
    messages_posted_by_members,
    members_who_posted,
    members_who_viewed,
    reactions_added,
    members_who_reacted,
    huddles_initiated,
    total_members,
    full_members,
    guests,
    date_created,
    last_message_at
from {{ source('raw', 'channel_activity_snapshot') }}
where source = 'admin_analytics_channel_range'
