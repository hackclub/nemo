{{ config(materialized='table', indexes=[{'columns': ['user_id'], 'unique': True}]) }}

with search as (
    select
        user_id,
        first_post_channel as channel_id,
        first_post_ts as posted_at
    from {{ ref('fct_member_history') }}
    where first_post_ts is not null
),

archive as (
    select user_id, channel_id, posted_at
    from {{ ref('fct_message_first_post') }}
),

merged as (
    select
        coalesce(a.user_id, s.user_id) as user_id,
        case
            when a.posted_at is null then s.channel_id
            when s.posted_at is null then a.channel_id
            when a.posted_at <= s.posted_at then a.channel_id
            else s.channel_id
        end as channel_id,
        least(
            coalesce(a.posted_at, s.posted_at),
            coalesce(s.posted_at, a.posted_at)
        ) as posted_at
    from archive a
    full outer join search s on s.user_id = a.user_id
)

select user_id, channel_id, posted_at
from merged
where posted_at is not null
