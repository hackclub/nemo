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
        h.channel_id,
        extract(isodow from h.ds)::integer as day_of_week,
        h.hour_of_day,
        sum(h.member_messages)::bigint as messages
    from {{ ref('fct_message_hour') }} h
    cross join span s
    inner join walked c on c.channel_id = h.channel_id
    where h.ds between s.window_start and s.window_end
    group by 1, 2, 3
)

select
    c.channel_id,
    c.day_of_week,
    c.hour_of_day,
    c.messages,
    s.window_start,
    s.window_end,
    'v3' as metric_version
from counted c
cross join span s
order by c.channel_id, c.day_of_week, c.hour_of_day
