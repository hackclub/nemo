select
    channel_id,
    oldest_ts,
    newest_ts,
    messages_seen,
    history_complete,
    last_walked_at,
    last_error
from {{ source('raw', 'channel_walk') }}
