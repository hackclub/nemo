with searched as (
    select
        user_id,
        total_messages
    from {{ ref('fct_member_history') }}
),

member_funnel as (
    select
        date_trunc('month', m.cohort_at)::date as cohort_month,
        m.cohort_at is not null as created_account,
        not m.invite_pending as signed_in,
        m.invite_pending or s.user_id is not null as post_knowable,
        coalesce(s.total_messages, 0) as total_messages
    from {{ ref('dim_member') }} m
    left join searched s on s.user_id = m.user_id
    where not m.is_bot and m.cohort_at is not null
),

sequential as (
    select
        cohort_month,
        created_account,
        signed_in,
        post_knowable,
        signed_in and total_messages >= 1 as posted_once,
        signed_in and total_messages >= 2 as posted_twice,
        signed_in and total_messages >= 3 as posted_three_times
    from member_funnel
),

gated as (
    select
        cohort_month,
        count(*) as total_members,
        count(*) filter (where created_account) as created_account,
        count(*) filter (where signed_in) as signed_in,
        count(*) filter (where post_knowable) as knowable,
        count(*) filter (where posted_once) as posted_once,
        count(*) filter (where posted_twice) as posted_twice,
        count(*) filter (where posted_three_times) as posted_three_times
    from sequential
    group by cohort_month
)

select
    cohort_month,
    total_members,
    created_account,
    signed_in,
    knowable,
    case when knowable > 0 then posted_once end as posted_once,
    case when knowable > 0 then posted_twice end as posted_twice,
    case when knowable > 0 then posted_three_times end as posted_three_times,
    'v13' as metric_version
from gated
order by cohort_month
