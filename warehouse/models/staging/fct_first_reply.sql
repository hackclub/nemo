with searched as (
    select
        h.user_id as newcomer_id,
        coalesce(r.replier_id, r.bot_replier_id) as replier_id,
        h.first_post_ts as post_at,
        h.first_post_channel as channel_id,
        coalesce(r.reply_ts, r.bot_reply_ts) as reply_at,
        coalesce(r.latency_seconds, r.bot_latency_seconds)::numeric as latency_seconds,
        r.replier_id is null as bot_only
    from {{ ref('fct_member_history') }} h
    inner join {{ ref('fct_member_first_reply') }} r on r.user_id = h.user_id
    where coalesce(r.replier_id, r.bot_replier_id) is not null
)

select
    s.newcomer_id,
    s.replier_id,
    s.post_at,
    s.channel_id,
    s.reply_at,
    s.latency_seconds,
    s.bot_only or coalesce(d.is_bot, false) as replied_by_bot
from searched s
left join {{ ref('dim_member') }} d on d.user_id = s.replier_id
