with searched as (
    select
        h.user_id as newcomer_id,
        r.replier_id,
        h.first_post_ts as post_at,
        h.first_post_channel as channel_id,
        r.reply_ts as reply_at,
        r.latency_seconds::numeric as latency_seconds,
        'search' as source
    from {{ ref('fct_member_history') }} h
    inner join {{ ref('fct_member_first_reply') }} r on r.user_id = h.user_id
    where r.replier_id is not null
),

event_first_posts as (
    select
        user_id,
        min(posted_at) as first_post_at
    from {{ ref('fct_message') }}
    where user_id not in (select user_id from {{ ref('fct_member_first_reply') }})
    group by user_id
),

event_post_details as (
    select
        fp.user_id as poster_id,
        fp.first_post_at,
        m.channel_id,
        m.ts as post_ts
    from event_first_posts fp
    inner join {{ ref('fct_message') }} m
        on m.user_id = fp.user_id and m.posted_at = fp.first_post_at
),

event_replies as (
    select
        p.poster_id as newcomer_id,
        m.user_id as replier_id,
        p.first_post_at as post_at,
        p.channel_id,
        m.posted_at as reply_at,
        extract(epoch from (m.posted_at - p.first_post_at)) as latency_seconds,
        'events' as source,
        row_number() over (partition by p.poster_id order by m.posted_at) as rn
    from event_post_details p
    inner join {{ ref('fct_message') }} m
        on m.thread_ts = p.post_ts and m.user_id != p.poster_id
),

unioned as (
    select newcomer_id, replier_id, post_at, channel_id, reply_at, latency_seconds, source
    from searched
    union all
    select newcomer_id, replier_id, post_at, channel_id, reply_at, latency_seconds, source
    from event_replies
    where rn = 1
)

select
    u.*,
    coalesce(d.is_bot, false) as replied_by_bot
from unioned u
left join {{ ref('dim_member') }} d on d.user_id = u.replier_id
