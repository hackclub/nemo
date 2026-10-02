select
    channel_id,
    root_ts,
    reply_count,
    reply_users_count,
    latest_reply_ts,
    replies_fetched,
    fetched_through_ts,
    fetched_at,
    replies_fetched >= reply_count as replies_complete,
    seen_at
from {{ source('raw', 'thread') }}
