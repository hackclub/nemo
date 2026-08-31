with member_cohort as (
    select
        user_id,
        not invite_pending as joined,
        date_trunc('month', cohort_at)::date as cohort_month
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
),

early as (
    select * from {{ ref('fct_member_early_activity') }}
),

sequential as (
    select
        mc.cohort_month,
        mc.joined,
        e.user_id is not null as reachable,
        coalesce(e.day_1_covered, false) as day_1_covered,
        coalesce(e.day_7_covered, false) as day_7_covered,
        coalesce(e.day_30_covered, false) as day_30_covered,
        mc.joined and coalesce(e.active_by_day_1, false) as active_by_day_1,
        mc.joined and coalesce(e.active_by_day_7, false) as active_by_day_7,
        mc.joined and coalesce(e.active_by_day_30, false) as active_by_day_30
    from member_cohort mc
    left join early e on e.user_id = mc.user_id
),

gated as (
    select
        cohort_month,
        count(*) as invited,
        count(*) filter (where joined) as joined,
        count(*) filter (where joined and not day_1_covered) = 0
            and count(*) filter (where joined) > 0 as day_1_knowable,
        count(*) filter (where joined and not day_7_covered) = 0
            and count(*) filter (where joined) > 0 as day_7_knowable,
        count(*) filter (where joined and not day_30_covered) = 0
            and count(*) filter (where joined) > 0 as day_30_knowable,
        count(*) filter (where active_by_day_1) as active_by_day_1,
        count(*) filter (where active_by_day_7) as active_by_day_7,
        count(*) filter (where active_by_day_30) as active_by_day_30
    from sequential
    group by cohort_month
)

select
    cohort_month,
    invited,
    joined,
    case when day_1_knowable then active_by_day_1 end as active_by_day_1,
    case when day_7_knowable then active_by_day_7 end as active_by_day_7,
    case when day_30_knowable then active_by_day_30 end as active_by_day_30,
    day_1_knowable,
    day_7_knowable,
    day_30_knowable,
    'v11' as metric_version
from gated
order by cohort_month
