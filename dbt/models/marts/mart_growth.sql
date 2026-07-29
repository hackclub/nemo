with cohort as (
    select
        date_trunc('month', account_created_verified)::date as month,
        account_created_verified::date as created_on,
        claimed_at is not null as claimed,
        claimed_at is not null
            and claimed_at::date <= account_created_verified::date + 30 as claimed_30d
    from {{ ref('dim_member') }}
    where account_created_verified is not null and not is_bot
)
select
    month,
    count(*) as created_members,
    count(*) filter (where claimed) as claimed_members,
    round(
        count(*) filter (where claimed)::numeric / nullif(count(*), 0),
        4
    ) as claim_rate,
    count(*) filter (where claimed_30d) as claimed_members_30d,
    round(
        count(*) filter (where claimed_30d)::numeric / nullif(count(*), 0),
        4
    ) as claim_rate_30d,
    (month + interval '1 month 29 days')::date as claim_rate_30d_final_on,
    max(created_on) as last_created_on,
    'v8' as metric_version
from cohort
group by month
order by month
