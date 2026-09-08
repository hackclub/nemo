select distinct on (author_id)
    author_id as user_id,
    channel_id,
    ts,
    posted_at
from {{ ref('fct_member_message') }}
order by author_id, posted_at, ts
