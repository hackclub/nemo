with checked as (
    select
        h.user_id,
        date_trunc('month', h.first_post_ts)::date as post_month,
        r.replier_id,
        r.bot_replier_id,
        r.latency_seconds,
        coalesce(d.is_bot, false) as replier_is_bot
    from {{ ref('fct_member_history') }} h
    inner join {{ ref('fct_member_first_reply') }} r on r.user_id = h.user_id
    left join {{ ref('dim_member') }} d on d.user_id = r.replier_id
    where h.first_post_ts is not null
      and coalesce(r.unreadable, false) = false
),

classified as (
    select
        post_month,
        case
            when replier_id is not null and not replier_is_bot then 'member'
            when replier_id is not null or bot_replier_id is not null then 'bot'
            else 'none'
        end as answered_by,
        case when replier_id is not null and not replier_is_bot then latency_seconds end as member_latency
    from checked
)

select
    post_month,
    count(*) as first_posts_checked,
    count(*) filter (where answered_by = 'member') as answered_by_member,
    count(*) filter (where answered_by = 'bot') as answered_by_bot,
    count(*) filter (where answered_by = 'none') as unanswered,
    round((percentile_cont(0.5) within group (order by member_latency))::numeric, 0)
        as median_member_latency_seconds,
    'v2' as metric_version
from classified
group by 1
order by 1
