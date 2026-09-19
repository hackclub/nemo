{% set window_days = 92 %}

{{ config(indexes=[
    {'columns': ['user_id', 'ds', 'hour_of_day'], 'unique': True},
    {'columns': ['user_id']},
    {'columns': ['ds']}
]) }}

with edge as (
    select max((posted_at at time zone 'UTC')::date) as last_day
    from {{ ref('fct_member_message') }}
),

span as (
    select
        (last_day - {{ window_days - 1 }})::date as window_start,
        last_day as window_end
    from edge
)

select
    m.author_id as user_id,
    (m.posted_at at time zone 'UTC')::date as ds,
    extract(hour from m.posted_at at time zone 'UTC')::integer as hour_of_day,
    count(*)::bigint as messages,
    'v1' as metric_version
from {{ ref('fct_member_message') }} m
cross join span s
where (m.posted_at at time zone 'UTC')::date between s.window_start - 1 and s.window_end + 1
group by 1, 2, 3
