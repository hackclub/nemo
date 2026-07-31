with slack as (
    select
        claimed_full_members_count,
        claimed_guests_count
    from {{ ref('fct_team_stats') }}
    order by ds desc
    limit 1
),
ours as (
    select
        sum(claimed) filter (
            where account_type not in ('Multi-Channel Guest', 'Single-Channel Guest')
        ) as full_claimed,
        sum(claimed) filter (
            where account_type in ('Multi-Channel Guest', 'Single-Channel Guest')
        ) as guest_claimed
    from {{ ref('mart_account_type') }}
),
checks as (
    select
        'full_members' as dimension,
        ours.full_claimed as ours,
        slack.claimed_full_members_count as slack,
        1.22 as max_ratio
    from ours
    cross join slack

    union all

    select
        'guests' as dimension,
        ours.guest_claimed as ours,
        slack.claimed_guests_count as slack,
        2.60 as max_ratio
    from ours
    cross join slack
)
select
    dimension,
    ours,
    slack,
    round(ours::numeric / nullif(slack, 0), 4) as ratio,
    max_ratio
from checks
where ours::numeric / nullif(slack, 0) > max_ratio
