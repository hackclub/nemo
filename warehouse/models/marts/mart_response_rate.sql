{% set newcomer_days = 30 %}

with newcomers as (
    select
        r.post_at,
        r.responded_at,
        r.bot_at,
        r.answered,
        r.bot_replied,
        r.latency_seconds
    from {{ ref('fct_first_response') }} r
    inner join {{ ref('dim_member') }} d on d.user_id = r.newcomer_id
    where d.cohort_at is not null
      and not coalesce(d.is_bot, false)
      and not coalesce(d.is_deleted, false)
      and not coalesce(d.invite_pending, false)
      and r.post_at <= d.cohort_at + interval '{{ newcomer_days }} days'
),

classified as (
    select
        date_trunc('month', post_at)::date as post_month,
        answered,
        bot_replied,
        bot_at is not null
            and (responded_at is null or bot_at < responded_at) as bot_replied_first,
        case when answered then latency_seconds end as member_latency
    from newcomers
)

select
    post_month,
    count(*) as first_posts_checked,
    count(*) filter (where answered) as answered_by_member,
    count(*) filter (where not answered and bot_replied) as answered_by_bot,
    count(*) filter (where not answered and not bot_replied) as unanswered,
    count(*) filter (where bot_replied_first) as bot_replied_first,
    count(*) filter (where bot_replied_first and answered) as bot_first_then_member,
    round((percentile_cont(0.5) within group (order by member_latency))::numeric, 0)
        as median_member_latency_seconds,
    'v3' as metric_version
from classified
group by 1
order by 1
