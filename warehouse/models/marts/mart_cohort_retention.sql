with cohort as (
    select
        m.user_id,
        date_trunc('month', m.cohort_at)::date as cohort_month
    from {{ ref('dim_member') }} m
    where m.cohort_at is not null
      and not m.is_bot
      and not m.invite_pending
),

posted as (
    select
        c.cohort_month,
        c.user_id,
        r.retained_day_30,
        r.retained_day_90,
        r.day_30_covered,
        r.day_90_covered,
        r.returned_next_day,
        r.third_visit_in_7_days,
        r.visits_knowable
    from cohort c
    inner join {{ ref('fct_member_retention') }} r on r.user_id = c.user_id
    where r.posted_within_30d
),

rolled as (
    select
        cohort_month,
        count(*) as first_posters,
        count(*) filter (where day_30_covered) as measured_day_30,
        count(*) filter (where day_30_covered and retained_day_30) as retained_day_30,
        count(*) filter (where day_90_covered) as measured_day_90,
        count(*) filter (where day_90_covered and retained_day_90) as retained_day_90,
        count(*) filter (where visits_knowable) as measured_visits,
        count(*) filter (where visits_knowable and returned_next_day) as returned_next_day,
        count(*) filter (where visits_knowable and third_visit_in_7_days)
            as third_visit_in_7_days
    from posted
    group by cohort_month
),

sized as (
    select cohort_month, count(*) as cohort_size
    from cohort
    group by cohort_month
)

select
    s.cohort_month,
    s.cohort_size,
    coalesce(r.first_posters, 0) as first_posters,
    coalesce(r.measured_day_30, 0) as measured_day_30,
    coalesce(r.retained_day_30, 0) as retained_day_30,
    case when coalesce(r.measured_day_30, 0) > 0
         then round(r.retained_day_30::numeric / r.measured_day_30, 4) end
        as retained_day_30_rate,
    coalesce(r.measured_day_90, 0) as measured_day_90,
    coalesce(r.retained_day_90, 0) as retained_day_90,
    case when coalesce(r.measured_day_90, 0) > 0
         then round(r.retained_day_90::numeric / r.measured_day_90, 4) end
        as retained_day_90_rate,
    coalesce(r.measured_visits, 0) as measured_visits,
    coalesce(r.returned_next_day, 0) as returned_next_day,
    coalesce(r.third_visit_in_7_days, 0) as third_visit_in_7_days,
    (s.cohort_month + interval '1 month' + interval '90 days')::date <= current_date
        as day_90_mature,
    'v2' as metric_version
from sized s
left join rolled r on r.cohort_month = s.cohort_month
order by s.cohort_month
