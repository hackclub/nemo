select
    channel_id,
    window_start,
    window_end,
    source,
    messages_posted,
    messages_posted_by_members,
    members_who_posted,
    change_in_members_who_posted,
    members_who_viewed,
    reactions_added,
    members_who_reacted,
    huddles_initiated
from {{ source('raw', 'channel_activity_snapshot') }}
