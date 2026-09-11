{{ config(materialized='table', indexes=[{'columns': ['month', 'user_id'], 'unique': True}]) }}

select
    date_trunc('month', posted_at at time zone 'UTC')::date as month,
    author_id as user_id,
    count(*)::integer as messages_posted,
    count(distinct (posted_at at time zone 'UTC')::date)::integer as days_posted,
    count(distinct channel_id)::integer as channels_posted_in,
    min(posted_at) as first_at,
    max(posted_at) as last_at
from {{ ref('fct_member_message') }}
group by 1, 2
