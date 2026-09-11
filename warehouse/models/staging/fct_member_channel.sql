select
    author_id as user_id,
    channel_id,
    count(*) as messages,
    min(ts) as first_ts,
    max(ts) as last_ts,
    max(posted_at)::date > min(posted_at)::date as returned
from {{ ref('fct_member_message') }}
group by author_id, channel_id
