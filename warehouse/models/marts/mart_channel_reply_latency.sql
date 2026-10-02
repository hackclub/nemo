{% set window_days = 90 %}

{{ config(indexes=[{'columns': ['channel_id', 'bucket_order'], 'unique': True}]) }}

with edge as (
    select max(ds) as last_day
    from {{ ref('mart_channel_day') }}
),

span as (
    select
        (last_day - {{ window_days - 1 }})::date as window_start,
        last_day as window_end
    from edge
),

walked as (
    select channel_id
    from {{ ref('fct_channel_walk') }}
    where coalesce(history_complete, false)
),

placed as (
    select
        f.channel_id,
        case
            when not coalesce(r.answered, false) then 7
            when r.latency_seconds < 60 then 0
            when r.latency_seconds < 300 then 1
            when r.latency_seconds < 900 then 2
            when r.latency_seconds < 3600 then 3
            when r.latency_seconds < 21600 then 4
            when r.latency_seconds < 86400 then 5
            else 6
        end as bucket_order
    from {{ ref('fct_message_first_post') }} f
    inner join walked w on w.channel_id = f.channel_id
    inner join {{ ref('dim_member') }} d on d.user_id = f.user_id
    inner join {{ ref('fct_first_response') }} r on r.newcomer_id = f.user_id
    cross join span s
    where not d.is_bot
      and not d.is_deleted
      and (f.posted_at at time zone 'UTC')::date between s.window_start and s.window_end
),

buckets (bucket_order, bucket, answered) as (
    values
        (0, 'under 1m', true),
        (1, '1 to 5m', true),
        (2, '5 to 15m', true),
        (3, '15m to 1h', true),
        (4, '1 to 6h', true),
        (5, '6 to 24h', true),
        (6, 'over 1d', true),
        (7, 'never', false)
),

whole as (
    select channel_id, count(*)::integer as checked
    from placed
    group by 1
)

select
    w.channel_id,
    b.bucket_order,
    b.bucket,
    b.answered,
    count(p.bucket_order)::integer as newcomers,
    w.checked,
    round(100.0 * count(p.bucket_order) / nullif(w.checked, 0), 2) as share_pct,
    e.window_start,
    e.window_end,
    'v3' as metric_version
from whole w
cross join buckets b
cross join span e
left join placed p
    on p.channel_id = w.channel_id
   and p.bucket_order = b.bucket_order
group by w.channel_id, b.bucket_order, b.bucket, b.answered, w.checked,
    e.window_start, e.window_end
