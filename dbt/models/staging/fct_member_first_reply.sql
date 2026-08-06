select
    user_id,
    replier_id,
    reply_ts,
    latency_seconds,
    bot_replier_id,
    bot_reply_ts,
    bot_latency_seconds,
    unreadable,
    reason,
    walk_version,
    fetched_at
from {{ source('raw', 'member_first_reply') }}
