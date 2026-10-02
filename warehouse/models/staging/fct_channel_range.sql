{{ config(materialized='table', indexes=[{'columns': ['channel_id'], 'unique': True}]) }}

with held as (
    select distinct window_start, window_end
    from {{ source('raw', 'channel_activity_snapshot') }}
    where source = 'admin_analytics_channel_range'
),

settled as (
    select
        split_part(slice_key, '..', 1)::date as window_start,
        split_part(slice_key, '..', 2)::date as window_end
    from {{ source('ingest', 'slice_coverage') }}
    where source_key = 'channel_range'
      and state in ('complete', 'superseded')
),

ranked as (
    select h.window_start, h.window_end, 0 as settled_first
    from held h
    join settled s
        on s.window_start = h.window_start
        and s.window_end = h.window_end

    union all

    select h.window_start, h.window_end, 1
    from held h
),

latest as (
    select window_start, window_end
    from ranked
    order by settled_first, window_end desc, window_start asc
    limit 1
)

select
    a.channel_id,
    a.window_start,
    a.window_end,
    a.messages_posted,
    a.messages_posted_by_members,
    a.members_who_posted,
    a.members_who_viewed,
    a.reactions_added,
    a.members_who_reacted,
    a.huddles_initiated,
    a.total_members,
    a.full_members,
    a.guests,
    a.date_created,
    a.last_message_at
from {{ source('raw', 'channel_activity_snapshot') }} a
join latest l
    on l.window_start = a.window_start
    and l.window_end = a.window_end
where a.source = 'admin_analytics_channel_range'
