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

totals as (
    select
        cohort_month,
        measure,
        coalesce(sum(value), 0)::bigint as measure_total
    from measured
    group by cohort_month, measure
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

bands (band_order, activity_band, band_top) as (
    values
        (0, '0', 0),
        (1, '1', 1),
        (2, '2-4', 4),
        (3, '5-16', 16),
        (4, '17-64', 64),
        (5, '65-256', 256),
        (6, '257-1024', 1024),
        (7, '1025-4096', 4096),
        (8, '4097+', null)
),

measures (measure, measure_label, measure_order) as (
    values
        ('messages_posted', 'messages sent', 1),
        ('members_who_posted', 'unique messagers', 2),
        ('members_who_viewed', 'unique readers', 3)
)

select
    c.cohort_month,
    m.measure,
    m.measure_label,
    m.measure_order,
    coalesce(t.measure_total, 0) as measure_total,
    b.band_order,
    b.activity_band,
    b.band_top::integer as band_top,
    count(p.band_order) as channels,
    c.window_start,
    c.window_end,
    'v3' as metric_version
from cohorts c
cross join measures m
cross join bands b
left join placed p
    on p.cohort_month = c.cohort_month
   and p.measure = m.measure
   and p.band_order = b.band_order
left join totals t
    on t.cohort_month = c.cohort_month
   and t.measure = m.measure
group by c.cohort_month, m.measure, m.measure_label, m.measure_order, t.measure_total,
    b.band_order, b.activity_band, b.band_top, c.window_start, c.window_end
order by c.cohort_month desc, m.measure_order, b.band_order
