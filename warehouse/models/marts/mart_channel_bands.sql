with ranged as (
    select
        cohort_month,
        window_start,
        window_end,
        messages_posted,
        members_who_posted,
        members_who_viewed
    from {{ ref('fct_channel_month') }}
),

cohorts as (
    select
        cohort_month,
        min(window_start) as window_start,
        max(window_end) as window_end
    from ranged
    group by cohort_month
),

measured as (
    select
        r.cohort_month,
        m.measure,
        m.value
    from ranged r
    cross join lateral (values
        ('messages_posted', r.messages_posted),
        ('members_who_posted', r.members_who_posted),
        ('members_who_viewed', r.members_who_viewed)
    ) as m (measure, value)
),

placed as (
    select
        cohort_month,
        measure,
        case
            when value is null then null
            when value = 0 then 0
            when value = 1 then 1
            when value <= 4 then 2
            when value <= 16 then 3
            when value <= 64 then 4
            when value <= 256 then 5
            when value <= 1024 then 6
            when value <= 4096 then 7
            else 8
        end as band_order
    from measured
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
        (8, '4097+')
),

measures (measure, measure_label, measure_order) as (
    values
        ('messages_posted', 'Messages sent', 1),
        ('members_who_posted', 'Unique messagers', 2),
        ('members_who_viewed', 'Unique readers', 3)
)

select
    c.cohort_month,
    m.measure,
    m.measure_label,
    m.measure_order,
    b.band_order,
    b.activity_band,
    count(p.band_order) as channels,
    c.window_start,
    c.window_end,
    'v2' as metric_version
from cohorts c
cross join measures m
cross join bands b
left join placed p
    on p.cohort_month = c.cohort_month
   and p.measure = m.measure
   and p.band_order = b.band_order
group by c.cohort_month, m.measure, m.measure_label, m.measure_order,
    b.band_order, b.activity_band, c.window_start, c.window_end
order by c.cohort_month desc, m.measure_order, b.band_order
