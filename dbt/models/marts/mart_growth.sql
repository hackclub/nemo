with joins as (
    select
        date_trunc('month', account_created)::date as month,
        count(*) as new_members
    from {{ ref('dim_member') }}
    where account_created is not null
    group by 1
),
leaves as (
    select
        date_trunc('month', deactivated_at)::date as month,
        count(*) as deactivated
    from {{ ref('dim_member') }}
    where deactivated_at is not null
    group by 1
)
select
    coalesce(joins.month, leaves.month) as month,
    coalesce(joins.new_members, 0) as new_members,
    coalesce(leaves.deactivated, 0) as deactivated,
    coalesce(joins.new_members, 0) - coalesce(leaves.deactivated, 0) as net_change,
    'v1' as metric_version
from joins
full outer join leaves on joins.month = leaves.month
order by month
