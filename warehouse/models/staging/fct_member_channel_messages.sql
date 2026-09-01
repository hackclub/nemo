select
    author_id as user_id,
    channel_id,
    count(*) as messages,
    min(posted_at) as first_at,
    max(posted_at) as last_at
from {{ ref('fct_message') }}
where author_kind = 'member' and author_id is not null
group by author_id, channel_id
