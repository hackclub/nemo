with known as (
    select
        coalesce(w.user_id, h.user_id) as user_id,
        coalesce(w.channel_messages_posted, h.total_messages, 0) as total_messages
    from {{ ref('fct_member_window') }} w
    full outer join {{ ref('fct_member_history') }} h using (user_id)
),

walkable as (
    select user_id
    from {{ ref('dim_member') }}
    where not is_bot and not invite_pending
),

population as (
    select k.total_messages
    from walkable w
    inner join known k on k.user_id = w.user_id
),

coverage as (
    select
        (select count(*) from walkable) as workspace_members,
        (select min(searched_at)::date from {{ ref('fct_member_history') }}) as window_start,
        (select max(searched_at)::date from {{ ref('fct_member_history') }}) as window_end
),

member_bands as (
    select
        case
            when total_messages = 0 then 0
            when total_messages = 1 then 1
            when total_messages <= 4 then 2
            when total_messages <= 16 then 3
            when total_messages <= 64 then 4
            when total_messages <= 256 then 5
            when total_messages <= 1024 then 6
            when total_messages <= 4096 then 7
            else 8
        end as band_order
    from population
),

bands (band_order, activity_band) as (
    values
        (0, '0'),
        (1, '1'),
        (2, '2-4'),
        (3, '5-16'),
        (4, '17-64'),
        (5, '65-256'),
        (6, '257-1024'),
        (7, '1025-4096'),
        (8, '>4096')
)

select
    b.band_order,
    b.activity_band,
    count(mb.band_order) as members,
    c.workspace_members,
    c.window_start,
    c.window_end,
    'v13' as metric_version
from bands b
cross join coverage c
left join member_bands mb on mb.band_order = b.band_order
group by b.band_order, b.activity_band, c.workspace_members, c.window_start, c.window_end
order by b.band_order
