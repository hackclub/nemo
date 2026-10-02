select
    first_seen_at,
    is_reply,
    deleted_at
from {{ source('archive', 'message') }}
