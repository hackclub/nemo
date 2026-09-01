select
    channel_id,
    name,
    visibility,
    coalesce(archived, true) as archived,
    date_created,
    last_active_at,
    thread_parents,
    thread_replies,
    threads_counted_at
from {{ source('raw', 'channel_dim') }}
