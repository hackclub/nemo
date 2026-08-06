select
    user_id,
    replier_id,
    reply_ts,
    latency_seconds,
    unreadable,
    reason,
    fetched_at
from {{ source('raw', 'member_first_reply') }}
