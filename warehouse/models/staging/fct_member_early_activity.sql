with joined as (
    select
        user_id,
        cohort_at::date as joined_on
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot and not invite_pending
),

active as (
    select
        user_id,
        window_start as active_date
    from {{ ref('fct_member_activity') }}
    where coalesce(days_active, 0) > 0
),

covered as (
    select distinct window_start as day
    from {{ ref('fct_member_activity') }}
),

coverage as (
    select
        d.joined_on,
        count(*) filter (where c.day = d.joined_on + 1) = 1 as day_1_covered,
        count(*) filter (
            where c.day between d.joined_on + 1 and d.joined_on + 7
        ) = 7 as day_7_covered,
        count(*) filter (
            where c.day between d.joined_on + 1 and d.joined_on + 30
        ) = 30 as day_30_covered
    from (select distinct joined_on from joined) d
    left join covered c on c.day between d.joined_on + 1 and d.joined_on + 30
    group by d.joined_on
),

per_member as (
    select
        j.user_id,
        j.joined_on,
        coalesce(bool_or(a.active_date = j.joined_on + 1), false) as active_by_day_1,
        coalesce(bool_or(
            a.active_date between j.joined_on + 1 and j.joined_on + 7
        ), false) as active_by_day_7,
        coalesce(bool_or(
            a.active_date between j.joined_on + 1 and j.joined_on + 30
        ), false) as active_by_day_30
    from joined j
    left join active a
        on a.user_id = j.user_id
        and a.active_date between j.joined_on + 1 and j.joined_on + 30
    group by j.user_id, j.joined_on
)

select
    p.user_id,
    p.joined_on,
    p.active_by_day_1,
    p.active_by_day_7,
    p.active_by_day_30,
    c.day_1_covered,
    c.day_7_covered,
    c.day_30_covered
from per_member p
inner join coverage c on c.joined_on = p.joined_on
