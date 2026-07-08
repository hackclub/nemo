select
    channel_id,
    name,
    visibility,
    archived,
    date_created,
    last_active_at,
    creator_id,
    total_members,
    full_members,
    guests
from {{ source('raw', 'channel_dim') }}
