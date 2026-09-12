{{ config(
    materialized='incremental',
    unique_key=['channel_id', 'ds', 'hour_of_day'],
    incremental_strategy='delete+insert',
    indexes=[{'columns': ['channel_id', 'ds', 'hour_of_day'], 'unique': True},
             {'columns': ['ds']}]
) }}

{% set lookback_hours = 2 %}

{% if is_incremental() %}
with touched as (
    select distinct
        channel_id,
        (posted_at at time zone 'UTC')::date as ds
    from {{ ref('fct_message') }}
    where observed_at > (
        select coalesce(max(observed_through), '-infinity'::timestamptz)
             - interval '{{ lookback_hours }} hours'
        from {{ this }}
    )
)
{% endif %}

select
    m.channel_id,
    (m.posted_at at time zone 'UTC')::date as ds,
    extract(hour from m.posted_at at time zone 'UTC')::integer as hour_of_day,
    count(*)::bigint as messages,
    count(*) filter (where m.is_reply)::bigint as replies,
    count(*) filter (
        where m.author_kind = 'member'
          and m.author_id is not null
          and coalesce(m.subtype, '') <> 'channel_join'
    )::bigint as member_messages,
    count(distinct m.author_id)::bigint as authors,
    min(m.posted_at) as first_at,
    max(m.posted_at) as last_at,
    max(m.observed_at) as observed_through
from {{ ref('fct_message') }} m
{% if is_incremental() %}
inner join touched t
    on t.channel_id = m.channel_id
   and t.ds = (m.posted_at at time zone 'UTC')::date
{% endif %}
group by 1, 2, 3
