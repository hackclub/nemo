with member_days as (
    select
        user_id,
        window_start as active_date,
        messages_posted
    from {{ source('raw', 'member_activity_snapshot') }}
    where window_start = window_end
        and coalesce(days_active, 0) > 0
),

first_post as (
    select
        user_id,
        min(active_date) as first_post_date
    from member_days
    where coalesce(messages_posted, 0) > 0
    group by user_id
),

ranked_active_days as (
    select
        d.user_id,
        d.active_date,
        row_number() over (partition by d.user_id order by d.active_date) as visit_number
    from member_days d
    inner join first_post f on f.user_id = d.user_id and d.active_date >= f.first_post_date
),

member_funnel as (
    select
        m.user_id,
        date_trunc('month', m.account_created_verified)::date as cohort_month,
        m.account_created_verified is not null as created_account,
        m.is_claimed as signed_in,
        f.first_post_date is not null as sent_message,
        exists (
            select 1 from ranked_active_days r
            where r.user_id = m.user_id
                and r.visit_number = 2
                and r.active_date <= f.first_post_date + interval '1 day'
        ) as returned_next_day,
        exists (
            select 1 from ranked_active_days r
            where r.user_id = m.user_id
                and r.visit_number = 3
                and r.active_date <= f.first_post_date + interval '7 day'
        ) as third_visit_in_7_days,
        exists (
            select 1 from ranked_active_days r
            where r.user_id = m.user_id
                and r.visit_number = 4
                and r.active_date <= f.first_post_date + interval '14 day'
        ) as fourth_visit_in_14_days
    from {{ ref('dim_member') }} m
    left join first_post f on f.user_id = m.user_id
    where not m.is_bot and m.account_created_verified is not null
),

sequential as (
    select
        cohort_month,
        created_account,
        signed_in,
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
)

select
    cohort_month,
    count(*) as total_members,
    count(*) filter (where created_account) as created_account,
    count(*) filter (where signed_in) as signed_in,
    count(*) filter (where sent_message) as sent_message,
    count(*) filter (where returned_next_day) as returned_next_day,
    count(*) filter (where third_visit_in_7_days) as third_visit_in_7_days,
    count(*) filter (where fourth_visit_in_14_days) as fourth_visit_in_14_days,
    'v6' as metric_version
from sequential
group by cohort_month
order by cohort_month
