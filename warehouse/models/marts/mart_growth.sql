with cohort as (
    select
        date_trunc('month', cohort_at)::date as month,
        cohort_at,
        cohort_at::date as created_on,
        claimed_at,
        is_claimed as claimed,
        coalesce(invite_pending, false) as still_invited
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
),

counted as (
    select
        month,
        count(*) as invited_members,
        count(*) filter (where still_invited) as unclaimed_members,
        count(*) filter (where claimed) as claimed_members,
        count(*) filter (where claimed and claimed_at is null) as undated_claims,
        count(*) filter (where claimed_at < cohort_at + interval '30 days')
            as claimed_within_30d,
        max(created_on) as last_created_on
    from cohort
    group by month
)

select
    month,
    invited_members,
    unclaimed_members,
    claimed_members,
    undated_claims,
    undated_claims::numeric / nullif(invited_members, 0) <= 0.01 as claim_dates_complete,
    round(claimed_members::numeric / nullif(invited_members, 0), 4) as claim_rate,
    claimed_within_30d,
    case
        when undated_claims::numeric / nullif(invited_members, 0) <= 0.01
        then round(claimed_within_30d::numeric / nullif(invited_members, 0), 4)
    end as claim_rate_30d,
    ((month + interval '1 month')::date + 30) as claim_rate_30d_final_on,
    last_created_on,
    'v13' as metric_version
from counted
order by month
