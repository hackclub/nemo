select
    payload->>'user' as user_id,
    payload->>'channel' as channel_id,
    payload->>'ts' as ts,
    payload->>'thread_ts' as thread_ts,
    to_timestamp((payload->>'ts')::double precision) as posted_at
from {{ source('raw', 'slack_events') }}
where event_type = 'message'
    and coalesce(payload->>'subtype', '') not in (
        'channel_join', 'channel_leave', 'group_join', 'group_leave',
        'channel_name', 'group_name', 'channel_topic', 'group_topic',
        'channel_purpose', 'group_purpose',
        'channel_archive', 'channel_unarchive', 'group_archive', 'group_unarchive',
        'channel_convert_to_private', 'channel_convert_to_public',
        'message_changed', 'message_deleted',
        'pinned_item', 'unpinned_item',
        'reminder_add', 'channel_posting_permissions', 'ekm_access_denied',
        'message_replied', 'assistant_app_thread', 'bot_message'
    )
