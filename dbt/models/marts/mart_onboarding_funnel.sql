with member_cohort as (
    select
        user_id,
        not invite_pending as joined,
        date_trunc('month', cohort_at)::date as cohort_month
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
),

searched as (
    select user_id from {{ ref('fct_member_history') }}
),

retention as (
    select * from {{ ref('fct_member_retention') }}
)

select
    mc.cohort_month,
    count(*) as invited,
    count(*) filter (where mc.joined) as joined,
    case
        when count(*) filter (where mc.joined and s.user_id is null) = 0
             and count(*) filter (where mc.joined) > 0
        then count(*) filter (where mc.joined and r.user_id is not null)
    end as first_post,
    case
        when count(*) filter (where r.user_id is not null and not r.day_30_covered) = 0
             and count(*) filter (where r.day_30_covered) > 0
        then count(*) filter (where r.retained_day_30)
    end as retained_day_30,
    case
        when count(*) filter (where r.user_id is not null and not r.day_90_covered) = 0
             and count(*) filter (where r.day_90_covered) > 0
        then count(*) filter (where r.retained_day_90)
    end as retained_day_90,
    (mc.cohort_month + interval '1 month' + interval '30 days') <= now()
        and count(*) filter (where r.user_id is not null and not r.day_30_covered) = 0
        and count(*) filter (where r.day_30_covered) > 0 as day_30_mature,
    (mc.cohort_month + interval '1 month' + interval '90 days') <= now()
        and count(*) filter (where r.user_id is not null and not r.day_90_covered) = 0
        and count(*) filter (where r.day_90_covered) > 0 as day_90_mature,
    'v9' as metric_version
from member_cohort mc
left join searched s on s.user_id = mc.user_id
left join retention r on r.user_id = mc.user_id
group by mc.cohort_month
order by mc.cohort_month
