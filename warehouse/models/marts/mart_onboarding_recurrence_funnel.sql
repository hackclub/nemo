with searched as (
    select user_id from {{ ref('fct_member_history') }}
),

retention as (
    select * from {{ ref('fct_member_retention') }}
),

member_funnel as (
    select
        m.user_id,
        date_trunc('month', m.cohort_at)::date as cohort_month,
        m.cohort_at is not null as created_account,
        not m.invite_pending as signed_in,
        r.user_id is not null as sent_message,
        m.invite_pending or s.user_id is not null as post_knowable,
        r.visits_knowable,
        r.returned_next_day,
        r.third_visit_in_7_days,
        r.fourth_visit_in_14_days
    from {{ ref('dim_member') }} m
    left join retention r on r.user_id = m.user_id
    left join searched s on s.user_id = m.user_id
    where not m.is_bot and m.cohort_at is not null
),

sequential as (
    select
        cohort_month,
        created_account,
        signed_in,
        post_knowable,
        visits_knowable,
        sent_message,
        sent_message
            and returned_next_day as returned_next_day,
        sent_message
            and returned_next_day
            and third_visit_in_7_days as third_visit_in_7_days,
        sent_message
            and returned_next_day
            and third_visit_in_7_days
            and fourth_visit_in_14_days as fourth_visit_in_14_days
    from member_funnel
),

gated as (
    select
        cohort_month,
        count(*) as total_members,
        count(*) filter (where created_account) as created_account,
        count(*) filter (where signed_in) as signed_in,
        count(*) filter (where not post_knowable) = 0 as posts_knowable,
        count(*) filter (where visits_knowable) > 0 as visits_knowable,
        count(*) filter (where sent_message) as sent_message,
        count(*) filter (where returned_next_day) as returned_next_day,
        count(*) filter (where third_visit_in_7_days) as third_visit_in_7_days,
        count(*) filter (where fourth_visit_in_14_days) as fourth_visit_in_14_days
    from sequential
    group by cohort_month
)

select
    cohort_month,
    total_members,
    created_account,
    signed_in,
    case when posts_knowable then sent_message end as sent_message,
    case when posts_knowable and visits_knowable then returned_next_day end as returned_next_day,
    case when posts_knowable and visits_knowable then third_visit_in_7_days end as third_visit_in_7_days,
    case when posts_knowable and visits_knowable then fourth_visit_in_14_days end as fourth_visit_in_14_days,
    posts_knowable,
    visits_knowable,
    'v11' as metric_version
from gated
order by cohort_month
