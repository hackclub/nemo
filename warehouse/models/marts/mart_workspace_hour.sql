{{ config(indexes=[
    {'columns': ['ds', 'hour_of_day'], 'unique': True}
]) }}

with walked as (
    select channel_id
    from {{ ref('fct_channel_walk') }}
    where coalesce(history_complete, false)
)

select
    h.ds,
    h.hour_of_day,
    sum(h.member_messages)::bigint as messages
from {{ ref('fct_message_hour') }} h
inner join walked c on c.channel_id = h.channel_id
group by 1, 2
