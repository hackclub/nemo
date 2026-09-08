{% set window_days = 90 %}

with edge as (
    select max((posted_at at time zone 'UTC')::date) as last_day
    from {{ ref('fct_message') }}
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
    cross join span s
    where w.oldest_ts is not null
      and to_timestamp(w.oldest_ts::numeric)::date <= s.window_start
),

posts as (
    select
        m.channel_id,
        extract(isodow from m.posted_at at time zone 'UTC')::integer as day_of_week,
        extract(hour from m.posted_at at time zone 'UTC')::integer as hour_of_day
    from {{ ref('fct_member_message') }} m
    cross join span s
    inner join walked c on c.channel_id = m.channel_id
    where (m.posted_at at time zone 'UTC')::date between s.window_start and s.window_end
),

counted as (
    select channel_id, day_of_week, hour_of_day, count(*) as messages
    from posts
    group by channel_id, day_of_week, hour_of_day
),

sized as (
    select channel_id, sum(messages)::bigint as channel_messages
    from counted
    group by channel_id
)

select
    c.channel_id,
    c.day_of_week,
    c.hour_of_day,
    c.messages,
    z.channel_messages,
    s.window_start,
    s.window_end,
    'v1' as metric_version
from counted c
join sized z on z.channel_id = c.channel_id
cross join span s
order by c.channel_id, c.day_of_week, c.hour_of_day
