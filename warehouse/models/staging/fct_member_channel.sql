select
    user_id,
    channel_id,
    messages,
    first_ts,
    last_ts,
    last_ts::date > first_ts::date as returned,
    searched_at
from {{ source('raw', 'member_channel_message') }}
