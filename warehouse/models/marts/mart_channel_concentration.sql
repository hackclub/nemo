{% set min_posters = 20 %}

{{ config(indexes=[
    {'columns': ['channel_id', 'month', 'poster_pct'], 'unique': True},
    {'columns': ['channel_id', 'month']}
]) }}

with posters as (
    select channel_id, month, user_id, messages, month_end
    from {{ ref('mart_channel_person') }}
    where messages > 0
),

sized as (
    select
        channel_id,
        month,
        count(*)::integer as posters,
        sum(messages)::bigint as messages
    from posters
    group by 1, 2
    having count(*) >= {{ min_posters }}
),

ranked as (
    select
        p.channel_id,
        p.month,
        p.messages,
        row_number() over (
            partition by p.channel_id, p.month order by p.messages, p.user_id
        ) as rn,
        s.posters,
        s.messages as channel_messages
    from posters p
    inner join sized s on s.channel_id = p.channel_id and s.month = p.month
),

cumulative as (
    select
        channel_id,
        month,
        rn,
        posters,
        channel_messages,
        messages,
        sum(messages) over (partition by channel_id, month order by rn) as cum_messages
    from ranked
),

gini as (
    select
        channel_id,
        month,
        round((2 * sum(rn::numeric * messages)
            / nullif(max(posters)::numeric * max(channel_messages), 0)
            - (max(posters) + 1.0) / max(posters))::numeric, 4) as gini
    from cumulative
    group by channel_id, month
),

steps (step) as (
    select generate_series(1, 20)
),

marks as (
    select
        s.channel_id,
        s.month,
        st.step * 5 as poster_pct,
        greatest(round(s.posters * st.step / 20.0), 1) as at_rn
    from sized s
    cross join steps st
),

points as (
    select
        m.channel_id,
        m.month,
        m.poster_pct,
        c.cum_messages,
        c.posters,
        c.channel_messages
    from marks m
    inner join cumulative c
        on c.channel_id = m.channel_id
       and c.month = m.month
       and c.rn = m.at_rn
),

head as (
    select
        channel_id,
        month,
        sum(messages) filter (where rn > posters - 10)::bigint as top_10_messages,
        min(rn) filter (where cum_messages >= channel_messages / 2.0) as half_at_rn
    from cumulative
    group by channel_id, month
)

select
    p.channel_id,
    p.month,
    p.poster_pct,
    round(100.0 * p.cum_messages / nullif(p.channel_messages, 0), 4) as message_pct,
    p.posters,
    p.channel_messages as messages,
    g.gini,
    h.top_10_messages,
    round(100.0 * h.top_10_messages / nullif(p.channel_messages, 0), 4) as top_10_pct,
    (p.posters - h.half_at_rn + 1)::integer as people_for_half,
    'v2' as metric_version
from points p
inner join gini g on g.channel_id = p.channel_id and g.month = p.month
inner join head h on h.channel_id = p.channel_id and h.month = p.month
