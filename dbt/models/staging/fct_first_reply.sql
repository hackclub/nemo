with first_posts as (
    select
        user_id,
        min(posted_at) as first_post_at
    from {{ ref('fct_message') }}
    group by user_id
),

first_post_details as (
    select
        fp.user_id as poster_id,
        fp.first_post_at,
        m.channel_id,
        m.ts as post_ts
    from first_posts fp
    inner join {{ ref('fct_message') }} m
        on m.user_id = fp.user_id and m.posted_at = fp.first_post_at
),

thread_replies as (
    select
        p.poster_id,
        p.first_post_at,
        p.post_ts,
        m.user_id as replier_id,
        m.posted_at as reply_at,
        row_number() over (partition by p.poster_id order by m.posted_at) as rn
    from first_post_details p
    inner join {{ ref('fct_message') }} m
        on m.thread_ts = p.post_ts and m.user_id != p.poster_id
)

select
    poster_id as newcomer_id,
    replier_id,
    post_ts,
    reply_at,
    extract(epoch from (reply_at - first_post_at)) as latency_seconds
from thread_replies
where rn = 1
