select
    author_id as user_id,
    channel_id,
    count(*) as messages,
    min(posted_at) as first_at,
    max(posted_at) as last_at
from {{ ref('fct_member_message') }}
group by author_id, channel_id
