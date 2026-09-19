{{ config(indexes=[
    {'columns': ['user_id', 'basis'], 'unique': True},
    {'columns': ['basis', 'streak_rank']}
]) }}

with posted_days as (
    select user_id, ds
    from {{ ref('mart_member_day') }}
    where messages > 0
),

online_days as (
    select user_id, window_start as ds
    from {{ ref('fct_member_activity') }}
    where coalesce(days_active, 0) > 0
),

days as (
    select 'posted' as basis, user_id, ds from posted_days
    union all
    select 'online' as basis, user_id, ds from online_days
),

edges as (
    select basis, max(ds) as through
    from days
    group by basis
),

marked as (
    select
        basis,
        user_id,
        ds,
        ds - (row_number() over (partition by basis, user_id order by ds))::integer as run_key
    from days
),

runs as (
    select
        basis,
        user_id,
        min(ds) as started_on,
        max(ds) as ended_on,
        count(*)::integer as days
    from marked
    group by basis, user_id, run_key
),

longest as (
    select distinct on (basis, user_id)
        basis,
        user_id,
        days as longest_days,
        started_on as longest_from,
        ended_on as longest_to
    from runs
    order by basis, user_id, days desc, started_on desc
),

live as (
    select distinct on (r.basis, r.user_id)
        r.basis,
        r.user_id,
        r.days as current_days,
        r.started_on as current_from,
        r.ended_on as current_to
    from runs r
    inner join edges e on e.basis = r.basis
    where r.ended_on >= e.through - 1
    order by r.basis, r.user_id, r.ended_on desc
),

ranked as (
    select
        basis,
        user_id,
        current_days,
        current_from,
        current_to,
        (rank() over (partition by basis order by current_days desc))::integer as streak_rank,
        (count(*) over (partition by basis))::integer as streak_of
    from live
)

select
    l.basis,
    l.user_id,
    coalesce(r.current_days, 0) as current_days,
    r.current_from,
    r.current_to,
    r.streak_rank,
    r.streak_of,
    l.longest_days,
    l.longest_from,
    l.longest_to,
    e.through as measured_through,
    'v3' as metric_version
from longest l
inner join edges e on e.basis = l.basis
left join ranked r on r.basis = l.basis and r.user_id = l.user_id
