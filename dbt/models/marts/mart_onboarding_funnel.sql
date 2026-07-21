with member_cohort as (
    select
        user_id,
        account_created,
        claimed_at,
        date_trunc('month', coalesce(claimed_at, account_created))::date as cohort_month
    from {{ ref('dim_member') }}
    where account_created is not null or claimed_at is not null
),

first_posts as (
    select
        user_id,
        min(posted_at) as first_post_at
    from {{ ref('fct_message') }}
    group by user_id
),

retention_checks as (
    select
        mc.user_id,
        exists (
            select 1 from {{ source('raw', 'member_activity_snapshot') }} a
            where a.user_id = mc.user_id
                and a.window_start = a.window_end
                and coalesce(a.days_active, 0) > 0
                and a.window_start between mc.claimed_at::date + 23 and mc.claimed_at::date + 30
        ) as retained_day_30,
        exists (
            select 1 from {{ source('raw', 'member_activity_snapshot') }} a
            where a.user_id = mc.user_id
                and a.window_start = a.window_end
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
    count(*) filter (where mc.claimed_at is not null and fp.first_post_at is not null) as first_post,
    count(*) filter (where rc.retained_day_30) as retained_day_30,
    count(*) filter (where rc.retained_day_90) as retained_day_90,
    (mc.cohort_month + interval '1 month' + interval '30 days') <= now() as day_30_mature,
    (mc.cohort_month + interval '1 month' + interval '90 days') <= now() as day_90_mature,
    'v1' as metric_version
from member_cohort mc
left join first_posts fp on fp.user_id = mc.user_id
left join retention_checks rc on rc.user_id = mc.user_id
group by mc.cohort_month
order by mc.cohort_month
