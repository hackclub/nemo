with member_totals as (
    select
        user_id,
        sum(coalesce(messages_posted, 0)) as total_messages_posted
    from {{ source('raw', 'member_activity_snapshot') }}
    group by user_id
),

members as (
    select
        m.user_id,
        coalesce(t.total_messages_posted, 0) as total_messages_posted
    from {{ ref('dim_member') }} m
    left join member_totals t on t.user_id = m.user_id
),

thresholds as (
    select unnest(array[1, 2, 5, 10, 20, 50, 100]) as threshold
),

member_count as (
    select count(*) as total_members from members
)

select
    th.threshold,
    count(*) filter (where mm.total_messages_posted > th.threshold) as members_above_threshold,
    round(
        count(*) filter (where mm.total_messages_posted > th.threshold)::numeric
        / nullif((select total_members from member_count), 0),
        4
    ) as share_above_threshold,
    'v1' as metric_version
from thresholds th
cross join members mm
group by th.threshold
order by th.threshold
