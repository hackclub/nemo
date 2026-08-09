select
    user_id,
    first_post_channel as channel_id,
    first_post_ts as posted_at
from {{ ref('fct_member_history') }}
where first_post_ts is not null
