with counted as (
    select
        count(*) filter (where claimed_at < account_created_verified) as backwards,
        count(*) as members
    from {{ ref('dim_member') }}
)

select
    backwards,
    members,
    round(100.0 * backwards / nullif(members, 0), 3) as share_pct,
    0.5 as max_share_pct
from counted
where backwards::numeric / nullif(members, 0) > 0.005
