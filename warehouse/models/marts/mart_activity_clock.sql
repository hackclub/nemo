{% set window_days = 90 %}

with edge as (
    select max(ds) as last_day
    from {{ ref('fct_message_hour') }}
),

span as (
    select
        (last_day - {{ window_days - 1 }})::date as window_start,
        last_day as window_end
    from edge
),

walked as (
    select w.channel_id
    from {{ ref('fct_channel_walk') }} w
    where coalesce(w.history_complete, false)
),

counted as (
    select
        extract(isodow from h.ds)::integer as day_of_week,
        h.hour_of_day,
        sum(h.member_messages)::bigint as messages
    from {{ ref('fct_message_hour') }} h
    cross join span s
    inner join walked c on c.channel_id = h.channel_id
    where h.ds between s.window_start and s.window_end
    group by 1, 2
),

grid as (
    select d.day_of_week, h.hour_of_day
    from generate_series(1, 7) d(day_of_week)
    cross join generate_series(0, 23) h(hour_of_day)
)

select
    g.day_of_week,
    g.hour_of_day,
    coalesce(c.messages, 0) as messages,
    s.window_start,
    s.window_end,
    'v3' as metric_version
from grid g
cross join span s
left join counted c
    on c.day_of_week = g.day_of_week and c.hour_of_day = g.hour_of_day
order by g.day_of_week, g.hour_of_day
