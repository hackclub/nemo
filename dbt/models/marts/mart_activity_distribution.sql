with member_totals as (
    select
        user_id,
        sum(coalesce(messages_posted, 0)) as messages_posted
    from {{ ref('fct_member_activity') }}
    group by user_id
),

members as (
    select
        m.user_id,
        coalesce(t.messages_posted, 0) as messages_posted
    from {{ ref('dim_member') }} m
    left join member_totals t on t.user_id = m.user_id
),

member_bands as (
    select
        case
            when messages_posted = 0 then 0
            when messages_posted < 2 then 1
            when messages_posted < 5 then 2
            when messages_posted < 10 then 3
            when messages_posted < 20 then 4
            when messages_posted < 50 then 5
            when messages_posted < 100 then 6
            else 7
        end as band_order
    from members
),

bands (band_order, activity_band) as (
    values
        (0, '0 (dormant)'),
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
    'v1' as metric_version
from bands b
left join member_bands mb on mb.band_order = b.band_order
group by b.band_order, b.activity_band
order by b.band_order
