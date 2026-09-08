select
    author_id as user_id,
    count(*) as total_messages,
    min(posted_at) as first_post_at,
    max(posted_at) as last_post_at,
    count(distinct channel_id) as channels_posted_in
from {{ ref('fct_member_message') }}
group by author_id
