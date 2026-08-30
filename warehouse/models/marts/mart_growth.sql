with cohort as (
    select
        date_trunc('month', cohort_at)::date as month,
        cohort_at::date as created_on,
        is_claimed as claimed,
        coalesce(invite_pending, false) as still_invited
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
)
select
    month,
    count(*) as invited_members,
    count(*) filter (where still_invited) as unclaimed_members,
    count(*) filter (where claimed) as claimed_members,
    round(count(*) filter (where claimed)::numeric / nullif(count(*), 0), 4) as claim_rate,
    max(created_on) as last_created_on,
    'v12' as metric_version
from cohort
group by month
order by month
