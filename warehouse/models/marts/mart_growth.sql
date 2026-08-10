with cohort as (
    select
        date_trunc('month', cohort_at)::date as month,
        cohort_at::date as created_on,
        is_claimed as claimed,
        case
            when claimed_at is not null then claimed_at::date <= cohort_at::date + 30
            when is_claimed then cohort_at::date > current_date - 30
            else false
        end as claimed_30d,
        is_claimed
            and claimed_at is null
            and cohort_at::date <= current_date - 30 as claim_timing_unknown
    from {{ ref('dim_member') }}
    where cohort_at is not null and not is_bot
)
select
    month,
    count(*) as created_members,
    count(*) filter (where claimed) as claimed_members,
    round(
        count(*) filter (where claimed)::numeric / nullif(count(*), 0),
        4
    ) as claim_rate,
    case
        when count(*) filter (where claim_timing_unknown) = 0
        then count(*) filter (where claimed_30d)
    end as claimed_members_30d,
    case
        when count(*) filter (where claim_timing_unknown) = 0
        then round(
            count(*) filter (where claimed_30d)::numeric / nullif(count(*), 0),
            4
        )
    end as claim_rate_30d,
    (month + interval '1 month 29 days')::date as claim_rate_30d_final_on,
    max(created_on) as last_created_on,
    'v10' as metric_version
from cohort
group by month
order by month
