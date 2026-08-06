with covered_days as (
    select distinct window_start as day
    from {{ ref('fct_member_activity') }}
),

member_cohort as (
    select
        user_id,
        claimed_at,
        not invite_pending as joined,
        date_trunc('month', cohort_at)::date as cohort_month
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
),

searched as (
    select user_id from {{ ref('fct_member_history') }}
),

first_posts as (
    select user_id from {{ ref('fct_first_post') }}
),

retention_checks as (
    select
        mc.user_id,
        exists (
            select 1 from covered_days d
            where d.day between mc.claimed_at::date + 23 and mc.claimed_at::date + 30
        ) as day_30_covered,
        exists (
            select 1 from covered_days d
            where d.day between mc.claimed_at::date + 83 and mc.claimed_at::date + 90
        ) as day_90_covered,
        exists (
            select 1 from {{ ref('fct_member_activity') }} a
            where a.user_id = mc.user_id
                and coalesce(a.days_active, 0) > 0
                and a.window_start between mc.claimed_at::date + 23 and mc.claimed_at::date + 30
        ) as retained_day_30,
        exists (
            select 1 from {{ ref('fct_member_activity') }} a
            where a.user_id = mc.user_id
                and coalesce(a.days_active, 0) > 0
                and a.window_start between mc.claimed_at::date + 83 and mc.claimed_at::date + 90
        ) as retained_day_90
    from member_cohort mc
    where mc.claimed_at is not null
)

select
    mc.cohort_month,
    count(*) as invited,
    count(*) filter (where mc.joined) as joined,
    case
        when count(*) filter (where mc.joined and s.user_id is null) = 0
             and count(*) filter (where mc.joined) > 0
        then count(*) filter (where mc.joined and fp.user_id is not null)
    end as first_post,
    case
        when count(*) filter (where mc.claimed_at is not null and not rc.day_30_covered) = 0
             and count(*) filter (where rc.day_30_covered) > 0
        then count(*) filter (where rc.retained_day_30)
    end as retained_day_30,
    case
        when count(*) filter (where mc.claimed_at is not null and not rc.day_90_covered) = 0
             and count(*) filter (where rc.day_90_covered) > 0
        then count(*) filter (where rc.retained_day_90)
    end as retained_day_90,
    (mc.cohort_month + interval '1 month' + interval '30 days') <= now()
        and count(*) filter (where mc.claimed_at is not null and not rc.day_30_covered) = 0
        and count(*) filter (where rc.day_30_covered) > 0 as day_30_mature,
    (mc.cohort_month + interval '1 month' + interval '90 days') <= now()
        and count(*) filter (where mc.claimed_at is not null and not rc.day_90_covered) = 0
        and count(*) filter (where rc.day_90_covered) > 0 as day_90_mature,
    'v7' as metric_version
from member_cohort mc
left join searched s on s.user_id = mc.user_id
left join first_posts fp on fp.user_id = mc.user_id
left join retention_checks rc on rc.user_id = mc.user_id
group by mc.cohort_month
order by mc.cohort_month
