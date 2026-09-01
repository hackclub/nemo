select distinct on (author_id)
    author_id as user_id,
    channel_id,
    ts,
    posted_at
from {{ ref('fct_message') }}
where author_kind = 'member' and author_id is not null
order by author_id, posted_at, ts
