select
    date_trunc('month', account_created_verified)::date as month,
    count(*) as created_members,
    count(*) filter (where claimed_at is not null) as claimed_members,
    round(
        count(*) filter (where claimed_at is not null)::numeric
        / nullif(count(*), 0),
        4
    ) as claim_rate,
    'v7' as metric_version
from {{ ref('dim_member') }}
where account_created_verified is not null and not is_bot
group by 1
order by month
