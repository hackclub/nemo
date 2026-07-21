with first_posts as (
    select
        user_id,
        channel_id,
        posted_at,
        date_trunc('month', posted_at)::date as post_month,
        row_number() over (partition by user_id order by posted_at) as rn
    from {{ ref('fct_message') }}
),

newcomer_first_posts as (
    select
        user_id,
        channel_id,
        post_month
    from first_posts
    where rn = 1
),

reply_info as (
    select
        newcomer_id,
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

scorecard_rows as (
    select
        nfp.channel_id,
        nfp.post_month,
        nfp.user_id,
        ri.fast_reply,
        exists (
            select 1 from {{ source('raw', 'member_activity_snapshot') }} a
            where a.user_id = nfp.user_id
                and a.window_start = a.window_end
                and coalesce(a.days_active, 0) > 0
                and a.window_start between mj.claimed_at::date + 83 and mj.claimed_at::date + 90
        ) as retained_day_90
    from newcomer_first_posts nfp
    inner join member_join mj on mj.user_id = nfp.user_id
    left join reply_info ri on ri.newcomer_id = nfp.user_id
)

select
    r.channel_id,
    c.name as channel_name,
    r.post_month,
    count(*) as newcomer_volume,
    count(*) filter (where r.fast_reply) as fast_reply_count,
    round(count(*) filter (where r.fast_reply)::numeric / nullif(count(*), 0), 4) as fast_reply_share,
    count(*) filter (where r.retained_day_90) as retained_90_count,
    round(count(*) filter (where r.retained_day_90)::numeric / nullif(count(*), 0), 4) as retained_90_share,
    (r.post_month + interval '1 month' + interval '90 days') <= now() as day_90_mature,
    'v1' as metric_version
from scorecard_rows r
left join {{ ref('dim_channel') }} c on c.channel_id = r.channel_id
group by r.channel_id, c.name, r.post_month
order by r.post_month, r.channel_id
