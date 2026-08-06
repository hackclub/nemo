select
    user_id,
    total_messages,
    first_post_ts,
    first_post_channel,
    searched_at
from {{ source('raw', 'member_message_history') }}
