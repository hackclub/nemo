with known as (
    select
        coalesce(l.user_id, h.user_id) as user_id,
        coalesce(l.total_messages, 0) as total_messages,
        h.user_id is not null as searched
    from {{ ref('fct_member_lifetime_messages') }} l
    full outer join {{ ref('fct_member_history') }} h using (user_id)
),

member_funnel as (
    select
        date_trunc('month', m.cohort_at)::date as cohort_month,
        not m.invite_pending as signed_in,
        not m.invite_pending and coalesce(k.searched, false) as searched,
        coalesce(k.total_messages, 0) as total_messages
    from {{ ref('dim_member') }} m
    left join known k on k.user_id = m.user_id
    where not m.is_bot and m.cohort_at is not null
),

sequential as (
    select
        cohort_month,
        signed_in,
        searched,
        searched and total_messages >= 1 as posted_once,
        searched and total_messages >= 2 as posted_twice,
        searched and total_messages >= 3 as posted_three_times
    from member_funnel
),

gated as (
    select
        cohort_month,
        count(*) as total_members,
        count(*) filter (where signed_in) as signed_in,
        count(*) filter (where searched) as searched,
        count(*) filter (where posted_once) as posted_once,
        count(*) filter (where posted_twice) as posted_twice,
        count(*) filter (where posted_three_times) as posted_three_times
    from sequential
    group by cohort_month
)

select
    cohort_month,
    total_members,
    total_members as created_account,
    signed_in,
    searched,
    searched as knowable,
    case when searched > 0 then posted_once end as posted_once,
    case when searched > 0 then posted_twice end as posted_twice,
    case when searched > 0 then posted_three_times end as posted_three_times,
    case when signed_in > 0 then round(searched::numeric / signed_in, 4) end as searched_share,
    'v17' as metric_version
from gated
order by cohort_month
