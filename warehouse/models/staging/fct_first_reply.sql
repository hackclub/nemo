with checked as (
    select
        h.user_id as newcomer_id,
        h.first_post_ts as post_at,
        h.first_post_channel as channel_id,
        coalesce(r.replier_id, r.bot_replier_id) as replier_id,
        coalesce(r.reply_ts, r.bot_reply_ts) as reply_at,
        coalesce(r.latency_seconds, r.bot_latency_seconds)::numeric as latency_seconds,
        r.replier_id is null as bot_only
    from {{ ref('fct_member_history') }} h
    inner join {{ ref('fct_member_first_reply') }} r on r.user_id = h.user_id
    where coalesce(r.unreadable, false) = false
)

select
    c.newcomer_id,
    c.replier_id,
    c.post_at,
    c.channel_id,
    c.reply_at,
    c.latency_seconds,
    c.replier_id is not null as answered,
    c.replier_id is not null
        and (c.bot_only or coalesce(d.is_bot, false)) as replied_by_bot
from checked c
left join {{ ref('dim_member') }} d on d.user_id = c.replier_id
