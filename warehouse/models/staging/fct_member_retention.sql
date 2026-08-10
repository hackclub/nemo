with first_post as (
    select
        user_id,
        posted_at::date as first_post_on
    from {{ ref('fct_first_post') }}
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
        w.first_post_on,
        count(*) filter (
            where c.day between w.first_post_on + 23 and w.first_post_on + 30
        ) > 0 as day_30_covered,
        count(*) filter (
            where c.day between w.first_post_on + 83 and w.first_post_on + 90
        ) > 0 as day_90_covered,
        count(*) filter (
            where c.day between w.first_post_on and w.first_post_on + 14
        ) = 15 as visits_knowable
    from (select distinct first_post_on from first_post) w
    left join covered c on c.day between w.first_post_on and w.first_post_on + 90
    group by w.first_post_on
),

visits as (
    select
        f.user_id,
        f.first_post_on,
        a.active_date,
        row_number() over (partition by f.user_id order by a.active_date) as visit_number
    from first_post f
    inner join active a on a.user_id = f.user_id and a.active_date >= f.first_post_on
),

per_member as (
    select
        f.user_id,
        f.first_post_on,
        coalesce(bool_or(
            v.active_date between f.first_post_on + 23 and f.first_post_on + 30
        ), false) as retained_day_30,
        coalesce(bool_or(
            v.active_date between f.first_post_on + 83 and f.first_post_on + 90
        ), false) as retained_day_90,
        coalesce(bool_or(
            v.visit_number = 2 and v.active_date <= f.first_post_on + 1
        ), false) as returned_next_day,
        coalesce(bool_or(
            v.visit_number = 3 and v.active_date <= f.first_post_on + 7
        ), false) as third_visit_in_7_days,
        coalesce(bool_or(
            v.visit_number = 4 and v.active_date <= f.first_post_on + 14
        ), false) as fourth_visit_in_14_days
    from first_post f
    left join visits v on v.user_id = f.user_id
    group by f.user_id, f.first_post_on
)

select
    m.user_id,
    m.first_post_on,
    m.retained_day_30,
    m.retained_day_90,
    m.returned_next_day,
    m.third_visit_in_7_days,
    m.fourth_visit_in_14_days,
    c.day_30_covered,
    c.day_90_covered,
    c.visits_knowable
from per_member m
inner join coverage c on c.first_post_on = m.first_post_on
