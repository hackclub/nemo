{{ config(indexes=[{'columns': ['ds'], 'unique': True}]) }}

with slack as (
    select
        window_start as ds,
        sum(messages_posted) as slack_messages,
        count(*) filter (where messages_posted > 0) as channels_active
    from {{ ref('fct_channel_activity') }}
    group by window_start
),

held as (
    select
        (posted_at at time zone 'UTC')::date as ds,
        count(*) as messages_held,
        count(*) filter (where not is_reply) as parents_held,
        count(*) filter (where is_reply) as replies_held,
        count(distinct channel_id) as channels_held
    from {{ ref('fct_message') }}
    group by 1
),

walked as (
    select
        count(*) filter (where history_complete) as complete_channels,
        count(*) filter (where unreachable_reason is not null) as unreachable_channels
    from {{ ref('mart_archive_channel_coverage') }}
)

select
    s.ds,
    s.slack_messages,
    s.channels_active,
    coalesce(h.messages_held, 0) as messages_held,
    coalesce(h.parents_held, 0) as parents_held,
    coalesce(h.replies_held, 0) as replies_held,
    coalesce(h.channels_held, 0) as channels_held,
    w.complete_channels,
    w.unreachable_channels,
    case
        when s.slack_messages > 0
        then round(100.0 * coalesce(h.messages_held, 0) / s.slack_messages, 1)
    end as held_share,
    'v1' as metric_version
from slack s
cross join walked w
left join held h on h.ds = s.ds
