select
    channel_id,
    name,
    visibility,
    coalesce(archived, true) as archived,
    date_created,
    last_active_at
from {{ source('raw', 'channel_dim') }}
