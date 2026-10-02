{{ config(materialized='table', indexes=[{'columns': ['user_id'], 'unique': True}]) }}

select
    user_id,
    sum(messages_posted)::integer as total_messages,
    sum(days_posted)::integer as days_posted,
    min(first_at) as first_at,
    max(last_at) as last_at
from {{ ref('fct_member_month_messages') }}
group by user_id
