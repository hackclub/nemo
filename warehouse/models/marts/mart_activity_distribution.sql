with known as (
    select
        coalesce(l.user_id, h.user_id) as user_id,
        coalesce(l.total_messages, 0) as total_messages,
        h.user_id is not null as full_history
    from {{ ref('fct_member_lifetime_messages') }} l
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
    where k.full_history
),

coverage as (
    select
        (select count(*) from walkable) as workspace_members,
        (select count(*) from population) as full_history_members
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
    c.full_history_members,
    'v17' as metric_version
from bands b
cross join coverage c
left join member_bands mb on mb.band_order = b.band_order
group by b.band_order, b.activity_band, c.workspace_members, c.full_history_members
order by b.band_order
