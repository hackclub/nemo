with walkable as (
    select user_id
    from {{ ref('dim_member') }}
    where not is_bot and not invite_pending
),

posters as (
    select
        h.user_id,
        h.total_messages,
        row_number() over (order by h.total_messages, h.user_id) as rn,
        count(*) over () as posters,
        sum(h.total_messages) over () as messages
    from {{ ref('fct_member_history') }} h
    inner join walkable w on w.user_id = h.user_id
    where h.total_messages > 0
),

cumulative as (
    select
        rn,
        posters,
        messages,
        total_messages,
        sum(total_messages) over (order by rn) as cum_messages
    from posters
),

gini as (
    select
        round((2 * sum(rn::numeric * total_messages)
            / nullif(posters * messages, 0) - (posters + 1.0) / posters)::numeric, 4) as gini
    from cumulative
    group by posters, messages
),

spread as (
    select
        percentile_disc(0.5) within group (order by total_messages)::integer as median_messages,
        percentile_disc(0.9) within group (order by total_messages)::integer as p90_messages
    from posters
),

steps (step) as (
    select generate_series(1, 20)
),

marks as (
    select
        s.step * 5 as poster_pct,
        (select max(rn) from cumulative where rn <= round(c.posters * s.step / 20.0)) as at_rn
    from steps s
    cross join (select distinct posters from cumulative) c
),

points as (
    select
        m.poster_pct,
        c.cum_messages,
        c.posters,
        c.messages
    from marks m
    inner join cumulative c on c.rn = m.at_rn
)

select
    p.poster_pct,
    round(100.0 * p.cum_messages / nullif(p.messages, 0), 4) as message_pct,
    p.posters,
    p.messages,
    g.gini,
    s.median_messages,
    s.p90_messages,
    (select count(*) from walkable) as workspace_members,
    (select count(*) from {{ ref('fct_member_history') }}) as searched_members,
    'v2' as metric_version
from points p
cross join gini g
cross join spread s
order by p.poster_pct
