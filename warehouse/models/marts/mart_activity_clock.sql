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
        extract(isodow from m.posted_at at time zone 'UTC')::integer as day_of_week,
        extract(hour from m.posted_at at time zone 'UTC')::integer as hour_of_day
    from {{ ref('fct_member_message') }} m
    cross join span s
    inner join walked c on c.channel_id = m.channel_id
    where (m.posted_at at time zone 'UTC')::date between s.window_start and s.window_end
),

counted as (
    select day_of_week, hour_of_day, count(*) as messages
    from posts
    group by day_of_week, hour_of_day
),

workspace as (
    select
        coalesce(sum(a.messages_posted_by_members), 0) as workspace_messages,
        coalesce(sum(a.messages_posted_by_members) filter (
            where w.channel_id is not null
        ), 0) as covered_messages
    from {{ ref('mart_channel_activity') }} a
    cross join span s
    left join walked w on w.channel_id = a.channel_id
    where a.window_start between s.window_start and s.window_end
),

coverage as (
    select
        (select count(*) from walked) as channels_counted,
        (select count(*) from posts) as messages_counted,
        (select covered_messages from workspace) as covered_messages,
        (select workspace_messages from workspace) as workspace_messages
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
    v.channels_counted::integer as channels_counted,
    v.messages_counted as messages_counted,
    v.covered_messages as covered_messages,
    v.workspace_messages as workspace_messages,
    s.window_start,
    s.window_end,
    'v1' as metric_version
from grid g
cross join coverage v
cross join span s
left join counted c
    on c.day_of_week = g.day_of_week and c.hour_of_day = g.hour_of_day
order by g.day_of_week, g.hour_of_day
