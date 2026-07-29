select
    window_start,
    window_end,
    user_id,
    display_name,
    messages_posted
from {{ source('raw', 'top_posters_snapshot') }}
