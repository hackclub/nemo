with cohort as (
    select
        date_trunc('month', d.cohort_at)::date as cohort_month,
        d.cohort_at,
        h.user_id is not null as searched,
        coalesce(h.total_messages, 0) > 0 as posted,
        h.first_post_ts
    from {{ ref('dim_member') }} d
    left join {{ ref('fct_member_history') }} h using (user_id)
    where d.cohort_at is not null
      and not d.is_bot
      and not d.invite_pending
)

select
    cohort_month,
    count(*) as members,
    count(*) filter (where searched) as searched,
    count(*) filter (where posted) as ever_posted,
    count(*) filter (where first_post_ts < cohort_at + interval '30 days') as posted_within_30d,
    round((percentile_cont(0.5) within group (
        order by extract(epoch from first_post_ts - cohort_at) / 86400.0
    ) filter (where first_post_ts is not null))::numeric, 1) as median_days_to_first_post,
    'v1' as metric_version
from cohort
group by 1
order by 1
