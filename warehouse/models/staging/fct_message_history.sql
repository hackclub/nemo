select
    author_id as user_id,
    count(*) as total_messages,
    min(posted_at) as first_post_at,
    max(posted_at) as last_post_at,
    count(distinct channel_id) as channels_posted_in
from {{ ref('fct_message') }}
where author_kind = 'member' and author_id is not null
group by author_id
