{{ config(materialized='table', indexes=[{'columns': ['user_id', 'channel_id'], 'unique': True}]) }}

select
    author_id as user_id,
    channel_id,
    count(*)::integer as messages,
    min(ts) as first_ts,
    max(ts) as last_ts,
    min(posted_at) as first_at,
    max(posted_at) as last_at,
    max(posted_at)::date > min(posted_at)::date as returned
from {{ ref('fct_member_message') }}
group by author_id, channel_id
