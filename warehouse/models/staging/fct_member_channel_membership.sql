select
    user_id,
    channel_id,
    seen_at
from {{ source('raw', 'member_channel_membership') }}
