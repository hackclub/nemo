with months as (
    select
        month,
        user_id,
        messages_posted,
        days_posted,
        (month + interval '1 month' - interval '1 day')::date as month_end
    from {{ ref('fct_member_month_messages') }}
),

edge as (
    select max((posted_at at time zone 'UTC')::date) as last_day
    from {{ ref('fct_message') }}
),

scoped as (
    select
        m.month,
        m.month as window_start,
        least(m.month_end, e.last_day) as window_end,
        m.user_id,
        m.messages_posted,
        m.days_posted
    from months m
    cross join edge e
    where m.month <= e.last_day
)

select
    s.month,
    s.window_start,
    s.window_end,
    (s.window_end - s.window_start + 1)::integer as days_in_window,
    s.user_id,
    s.messages_posted,
    s.days_posted,
    (s.window_end - s.window_start + 1)::integer as days_measured,
    row_number() over (
        partition by s.month
        order by s.messages_posted desc, s.user_id
    ) as rank,
    'v4' as metric_version
from scoped s
order by month desc, rank
