with window_bounds as (
    select
        min(window_start) as window_start,
        max(window_end) as window_end
    from {{ ref('fct_member_window') }}
),

member_activity as (
    select
        user_id,
        sum(coalesce(messages_posted, 0)) as messages_posted,
        sum(coalesce(days_active, 0)) as days_active
    from {{ ref('fct_member_window') }}
    group by user_id
),

members as (
    select
        coalesce(a.messages_posted, 0) as messages_posted,
        coalesce(a.days_active, 0) as days_active
    from {{ ref('dim_member') }} m
    left join member_activity a on a.user_id = m.user_id
    where m.is_live
),

member_bands as (
    select
        case
            when messages_posted = 0 and days_active = 0 then 0
            when messages_posted = 0 then 1
            when messages_posted < 2 then 2
            when messages_posted < 5 then 3
            when messages_posted < 10 then 4
            when messages_posted < 20 then 5
            when messages_posted < 50 then 6
            when messages_posted < 100 then 7
            else 8
        end as band_order
    from members
),

bands (band_order, activity_band) as (
    values
        (0, 'never active'),
        (1, 'active, no messages'),
        (2, '1'),
        (3, '2-4'),
        (4, '5-9'),
        (5, '10-19'),
        (6, '20-49'),
        (7, '50-99'),
        (8, '100+')
)

select
    b.band_order,
    b.activity_band,
    count(mb.band_order) as members,
    w.window_start,
    w.window_end,
    'v9' as metric_version
from bands b
cross join window_bounds w
left join member_bands mb on mb.band_order = b.band_order
group by b.band_order, b.activity_band, w.window_start, w.window_end
order by b.band_order
