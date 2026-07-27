with invited as (
    select
        date_trunc('month', account_created)::date as month,
        count(*) as invited_members
    from {{ ref('dim_member') }}
    where account_created is not null and not is_bot
    group by 1
),
joined as (
    select
        date_trunc('month', claimed_at)::date as month,
        count(*) as joined_members
    from {{ ref('dim_member') }}
    where claimed_at is not null and not is_bot
    group by 1
),
departed as (
    select
        date_trunc('month', deactivated_at)::date as month,
        count(*) as deactivated
    from {{ ref('dim_member') }}
    where deactivated_at is not null and not is_bot
    group by 1
)
select
    coalesce(invited.month, joined.month, departed.month) as month,
    coalesce(invited.invited_members, 0) as invited_members,
    coalesce(joined.joined_members, 0) as joined_members,
    coalesce(departed.deactivated, 0) as deactivated,
    coalesce(joined.joined_members, 0) - coalesce(departed.deactivated, 0) as net_change,
    'v4' as metric_version
from invited
full outer join joined on invited.month = joined.month
full outer join departed on coalesce(invited.month, joined.month) = departed.month
order by month
