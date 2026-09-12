{{ config(indexes=[{'columns': ['channel_id'], 'unique': True}]) }}

with held as (
    select
        channel_id,
        sum(messages) as messages_held,
        sum(replies) as replies_held,
        sum(messages) - sum(replies) as parents_held,
        min(first_at) as oldest_held,
        max(last_at) as newest_held
    from {{ ref('fct_message_hour') }}
    group by channel_id
),

threads as (
    select
        channel_id,
        count(*) as threads_known,
        count(*) filter (where fetched_at is not null) as threads_fetched,
        coalesce(sum(reply_count), 0) as replies_declared
    from {{ ref('fct_thread') }}
    group by channel_id
),

slack as (
    select
        channel_id,
        sum(messages_posted) as slack_messages,
        min(window_start) as slack_from,
        max(window_end) as slack_to
    from {{ ref('fct_channel_activity') }}
    group by channel_id
)

select
    c.channel_id,
    c.name,
    c.visibility,
    c.archived,
    w.channel_id is not null as walked,
    coalesce(w.history_complete, false) as history_complete,
    case
        when w.last_error like 'entity:%' then w.last_error
    end as unreachable_reason,
    w.last_walked_at,
    coalesce(h.messages_held, 0) as messages_held,
    coalesce(h.parents_held, 0) as parents_held,
    coalesce(h.replies_held, 0) as replies_held,
    h.oldest_held,
    h.newest_held,
    coalesce(t.threads_known, 0) as threads_known,
    coalesce(t.threads_fetched, 0) as threads_fetched,
    coalesce(t.replies_declared, 0) as replies_declared,
    coalesce(s.slack_messages, 0) as slack_messages,
    s.slack_from,
    s.slack_to,
    case
        when coalesce(s.slack_messages, 0) > 0
        then round(100.0 * coalesce(h.messages_held, 0) / s.slack_messages, 1)
    end as held_share,
    case
        when coalesce(t.replies_declared, 0) > 0
        then round(100.0 * coalesce(h.replies_held, 0) / t.replies_declared, 1)
    end as reply_share,
    'v1' as metric_version
from {{ ref('dim_channel') }} c
left join {{ ref('fct_channel_walk') }} w on w.channel_id = c.channel_id
left join held h on h.channel_id = c.channel_id
left join threads t on t.channel_id = c.channel_id
left join slack s on s.channel_id = c.channel_id
