with reply_speed as (
    select
        newcomer_id,
        latency_seconds,
        latency_seconds < 3600 as fast_reply
    from {{ ref('fct_first_reply') }}
),

member_join as (
    select
        user_id,
        claimed_at
    from {{ ref('dim_member') }}
    where claimed_at is not null
),

daily_activity as (
    select
        user_id,
        window_start as active_date
    from {{ source('raw', 'member_activity_snapshot') }}
    where window_start = window_end
        and coalesce(days_active, 0) > 0
),

retention as (
    select
        rs.newcomer_id,
        rs.fast_reply,
        exists (
            select 1 from daily_activity d
            where d.user_id = rs.newcomer_id
                and d.active_date between mj.claimed_at::date + 23 and mj.claimed_at::date + 30
        ) as retained_day_30,
        exists (
            select 1 from daily_activity d
            where d.user_id = rs.newcomer_id
                and d.active_date between mj.claimed_at::date + 83 and mj.claimed_at::date + 90
        ) as retained_day_90
    from reply_speed rs
    inner join member_join mj on mj.user_id = rs.newcomer_id
)

select
    fast_reply,
    count(*) as newcomers,
    count(*) filter (where retained_day_30) as retained_day_30_count,
    round(count(*) filter (where retained_day_30)::numeric / nullif(count(*), 0), 4) as retained_day_30_rate,
    count(*) filter (where retained_day_90) as retained_day_90_count,
    round(count(*) filter (where retained_day_90)::numeric / nullif(count(*), 0), 4) as retained_day_90_rate,
    'v1' as metric_version
from retention
group by fast_reply
