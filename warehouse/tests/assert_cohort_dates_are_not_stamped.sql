{{ config(severity='warn') }}

with cohorts as (
    select
        cohort_at::date as cohort_day,
        count(*) as members
    from {{ ref('dim_member') }}
    where cohort_at is not null
    group by 1
),

total as (
    select sum(members) as all_members from cohorts
)

select
    c.cohort_day,
    c.members,
    round(100.0 * c.members / nullif(t.all_members, 0), 2) as share_pct,
    10.0 as max_share_pct
from cohorts c
cross join total t
where c.members::numeric / nullif(t.all_members, 0) > 0.10
