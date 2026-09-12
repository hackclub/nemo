{{ config(
    materialized='incremental',
    unique_key='newcomer_id',
    on_schema_change='fail',
    indexes=[{'columns': ['newcomer_id'], 'unique': True}]
) }}

{% set detection_window_hours = 1 %}
{% set lookback_hours = 24 %}

with candidate_ids as (
    {% if is_incremental() %}
    -- a newcomer with no row yet: fct_message_first_post is a full rebuild every run,
    -- so this always reflects the true, current first-poster set - including one
    -- discovered by a backfill well after its actual (old) posted_at
    select f.user_id as newcomer_id
    from {{ ref('fct_message_first_post') }} f
    where not exists (select 1 from {{ this }} t where t.newcomer_id = f.user_id)

    union

    -- a newcomer already recorded whose thread or mentions just gained a message -
    -- observed_at is when the pipeline recorded it, so a reply that arrives (or is
    -- backfilled) long after the first post still lands here on the run that sees it
    select f.user_id as newcomer_id
    from {{ ref('fct_message_first_post') }} f
    join {{ ref('fct_message') }} m on m.channel_id = f.channel_id
    where m.ts <> f.ts
      and m.author_id is distinct from f.user_id
      and (m.thread_root_ts = f.ts or f.user_id = any(m.mentioned_ids))
      and m.observed_at > (
          select coalesce(max(post_at), '-infinity'::timestamptz)
               - interval '{{ lookback_hours }} hours'
          from {{ this }}
      )
    {% else %}
    select user_id as newcomer_id from {{ ref('fct_message_first_post') }}
    {% endif %}
),

first_posts as (
    select
        f.user_id as newcomer_id,
        f.channel_id,
        f.ts as post_ts,
        f.posted_at
    from {{ ref('fct_message_first_post') }} f
    join candidate_ids c on c.newcomer_id = f.user_id
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
),

-- pick the winning response once, on an explicit tie rule (thread wins a dead heat),
-- and read every derived field - time, method, confidence - off that same candidate,
-- rather than letting each field ask "does a thread reply exist" independently
resolved as (
    select
        f.newcomer_id,
        f.channel_id,
        f.posted_at,
        t.member_at as thread_at,
        c.member_at as channel_at,
        t.bot_at,
        t.member_at is not null and (c.member_at is null or t.member_at <= c.member_at)
            as thread_wins
    from first_posts f
    left join thread_replies t on t.newcomer_id = f.newcomer_id
    left join channel_mentions c on c.newcomer_id = f.newcomer_id
)

select
    r.newcomer_id,
    r.channel_id,
    r.posted_at as post_at,
    case when r.thread_wins then r.thread_at else r.channel_at end as responded_at,
    case
        when r.thread_wins then 'thread_reply'
        when r.channel_at is not null then 'in_channel_mention'
        when r.bot_at is not null then 'bot_only'
        else 'none'
    end as detection_method,
    case
        when r.thread_wins then 'high'
        when r.channel_at is not null then 'medium'
        else 'none'
    end as confidence,
    extract(epoch from
        (case when r.thread_wins then r.thread_at else r.channel_at end) - r.posted_at
    )::integer as latency_seconds,
    r.thread_at is not null as answered_in_thread,
    r.channel_at is not null as answered_in_channel,
    r.bot_at is not null as bot_replied,
    r.bot_at as bot_at,
    (case when r.thread_wins then r.thread_at else r.channel_at end) is not null as answered,
    coalesce(w.history_complete, false) as channel_history_complete
from resolved r
left join walked w on w.channel_id = r.channel_id
