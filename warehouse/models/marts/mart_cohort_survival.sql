{% set horizon = 90 %}

{{ config(indexes=[{'columns': ['cohort_month', 'day_offset'], 'unique': True}]) }}

with member as (
    select
        cohort_month,
        user_id,
        min(first_post_on) as first_post_on,
        max(ds) as last_post_on
    from {{ ref('fct_member_day') }}
    group by 1, 2
),

edge as (
    select max(ds) as watermark
    from {{ ref('fct_member_day') }}
),

sized as (
    select
        cohort_month,
        count(*) as members,
        max(first_post_on) as newest_first_post
    from member
    group by 1
),

offsets as (
    select generate_series(0, {{ horizon }}) as day_offset
)

select
    s.cohort_month,
    o.day_offset,
    s.members,
    count(*) filter (where m.last_post_on >= m.first_post_on + o.day_offset) as still_posting,
    round(
        100.0 * count(*) filter (where m.last_post_on >= m.first_post_on + o.day_offset)
            / nullif(s.members, 0), 2
    ) as still_posting_share,
    s.newest_first_post + o.day_offset <= e.watermark as observable,
    e.watermark as observed_through,
    {{ horizon }}::integer as horizon_days,
    'v1' as metric_version
from sized s
cross join offsets o
cross join edge e
inner join member m on m.cohort_month = s.cohort_month
group by s.cohort_month, o.day_offset, s.members, s.newest_first_post, e.watermark
order by s.cohort_month, o.day_offset
