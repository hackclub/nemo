with checked as (
    select
        h.user_id,
        date_trunc('month', h.first_post_ts)::date as post_month,
        r.replier_id,
        r.latency_seconds,
        coalesce(d.is_bot, false) as replied_by_bot
    from {{ ref('fct_member_history') }} h
    inner join {{ ref('fct_member_first_reply') }} r on r.user_id = h.user_id
    left join {{ ref('dim_member') }} d on d.user_id = r.replier_id
    where h.first_post_ts is not null
      and coalesce(r.unreadable, false) = false
)

select
    post_month,
    count(*) as first_posts_checked,
    count(*) filter (where replier_id is not null and not replied_by_bot) as answered_by_member,
    count(*) filter (where replier_id is not null and replied_by_bot) as answered_by_bot,
    count(*) filter (where replier_id is null) as unanswered,
    round((percentile_cont(0.5) within group (order by latency_seconds)
        filter (where replier_id is not null and not replied_by_bot))::numeric, 0) as median_member_latency_seconds,
    'v1' as metric_version
from checked
group by 1
order by 1
