with covered_days as (
    select distinct window_start as day
    from {{ ref('fct_member_activity') }}
),

coverage_bounds as (
    select min(day) as first_day, max(day) as last_day from covered_days
),

member_cohort as (
    select
        user_id,
        claimed_at,
        date_trunc('month', cohort_at)::date as cohort_month
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
),

first_posts as (
    select
        user_id,
        min(window_start) as first_post_at
    from {{ ref('fct_member_activity') }}
    where coalesce(messages_posted, 0) > 0
    group by user_id
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
        mc.claimed_at::date >= (select first_day from coverage_bounds)
            and mc.claimed_at::date <= (select last_day from coverage_bounds) as first_post_knowable,
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
    count(*) filter (where mc.claimed_at is not null) as joined,
    case
        when count(*) filter (where mc.claimed_at is not null and not rc.first_post_knowable) = 0
             and count(*) filter (where rc.first_post_knowable) > 0
        then count(*) filter (where mc.claimed_at is not null and fp.first_post_at is not null)
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
    'v6' as metric_version
from member_cohort mc
left join first_posts fp on fp.user_id = mc.user_id
left join retention_checks rc on rc.user_id = mc.user_id
group by mc.cohort_month
order by mc.cohort_month
