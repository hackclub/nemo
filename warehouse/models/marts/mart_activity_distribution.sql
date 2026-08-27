with searched as (
    select
        user_id,
        total_messages
    from {{ ref('fct_member_history') }}
),

walkable as (
    select user_id
    from {{ ref('dim_member') }}
    where not is_bot and not invite_pending
),

population as (
    select s.total_messages
    from walkable w
    inner join searched s on s.user_id = w.user_id
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
            when total_messages < 2 then 1
            when total_messages < 5 then 2
            when total_messages < 10 then 3
            when total_messages < 20 then 4
            when total_messages < 50 then 5
            when total_messages < 100 then 6
            else 7
        end as band_order
    from population
),

bands (band_order, activity_band) as (
    values
        (0, 'no messages ever'),
        (1, '1'),
        (2, '2-4'),
        (3, '5-9'),
        (4, '10-19'),
        (5, '20-49'),
        (6, '50-99'),
        (7, '100+')
)

select
    b.band_order,
    b.activity_band,
    count(mb.band_order) as members,
    c.workspace_members,
    c.window_start,
    c.window_end,
    'v11' as metric_version
from bands b
cross join coverage c
left join member_bands mb on mb.band_order = b.band_order
group by b.band_order, b.activity_band, c.workspace_members, c.window_start, c.window_end
order by b.band_order
