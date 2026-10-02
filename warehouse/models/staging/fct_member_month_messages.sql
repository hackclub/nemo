{{ config(
    materialized='incremental',
    unique_key=['month', 'user_id'],
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns',
    indexes=[{'columns': ['month', 'user_id'], 'unique': True}]
) }}

{% set lookback_hours = 2 %}

{% if is_incremental() %}
with touched as (
    select distinct date_trunc('month', posted_at at time zone 'UTC')::date as month
    from {{ ref('fct_member_message') }}
    where observed_at > (
        select coalesce(max(observed_through), '-infinity'::timestamptz)
             - interval '{{ lookback_hours }} hours'
        from {{ this }}
    )
)
{% endif %}

select
    date_trunc('month', m.posted_at at time zone 'UTC')::date as month,
    m.author_id as user_id,
    count(*)::integer as messages_posted,
    count(distinct (m.posted_at at time zone 'UTC')::date)::integer as days_posted,
    count(distinct m.channel_id)::integer as channels_posted_in,
    min(m.posted_at) as first_at,
    max(m.posted_at) as last_at,
    max(m.observed_at) as observed_through
from {{ ref('fct_member_message') }} m
{% if is_incremental() %}
inner join touched t
    on t.month = date_trunc('month', m.posted_at at time zone 'UTC')::date
{% endif %}
group by 1, 2
