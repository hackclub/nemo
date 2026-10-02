{{ config(
    materialized='incremental',
    unique_key='newcomer_id',
    on_schema_change='fail',
    indexes=[{'columns': ['newcomer_id'], 'unique': True}]
) }}

{% set detection_window_hours = 1 %}
{% set lookback_hours = 24 %}

with first_posts as (
    select
        user_id as newcomer_id,
        channel_id,
        ts as post_ts,
        posted_at
    from {{ ref('fct_message_first_post') }}
    {% if is_incremental() %}
    where posted_at > (
        select coalesce(max(post_at), '-infinity'::timestamptz)
             - interval '{{ lookback_hours }} hours'
        from {{ this }}
    )
    {% endif %}
),

thread_replies as (
    select
        f.newcomer_id,
        min(m.posted_at) filter (where m.author_kind = 'member') as member_at,
        min(m.posted_at) filter (where m.author_kind = 'bot') as bot_at,
        count(*) as candidates
    from first_posts f
    join {{ ref('fct_message') }} m
      on m.channel_id = f.channel_id
     and m.thread_root_ts = f.post_ts
     and m.ts <> f.post_ts
     and m.author_id is distinct from f.newcomer_id
    group by f.newcomer_id
),

channel_mentions as (
    select
        f.newcomer_id,
        min(m.posted_at) filter (where m.author_kind = 'member') as member_at,
        count(*) as candidates
    from first_posts f
    join {{ ref('fct_message') }} m
      on m.channel_id = f.channel_id
     and m.posted_at > f.posted_at
     and m.posted_at <= f.posted_at + interval '{{ detection_window_hours }} hour'
     and m.author_id is distinct from f.newcomer_id
     and f.newcomer_id = any(m.mentioned_ids)
    group by f.newcomer_id
),

walked as (
    select channel_id, history_complete from {{ ref('fct_channel_walk') }}
)

select
    f.newcomer_id,
    f.channel_id,
    f.posted_at as post_at,
    least(t.member_at, c.member_at) as responded_at,
    case
        when t.member_at is not null then 'thread_reply'
        when c.member_at is not null then 'in_channel_mention'
        when t.bot_at is not null then 'bot_only'
        else 'none'
    end as detection_method,
    case
        when t.member_at is not null then 'high'
        when c.member_at is not null then 'medium'
        else 'none'
    end as confidence,
    extract(epoch from least(t.member_at, c.member_at) - f.posted_at)::integer
        as latency_seconds,
    t.member_at is not null as answered_in_thread,
    c.member_at is not null as answered_in_channel,
    t.bot_at is not null as bot_replied,
    t.bot_at as bot_at,
    least(t.member_at, c.member_at) is not null as answered,
    coalesce(w.history_complete, false) as channel_history_complete
from first_posts f
left join thread_replies t on t.newcomer_id = f.newcomer_id
left join channel_mentions c on c.newcomer_id = f.newcomer_id
left join walked w on w.channel_id = f.channel_id
