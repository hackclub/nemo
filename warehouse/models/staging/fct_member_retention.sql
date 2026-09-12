{{ config(
    materialized='incremental',
    unique_key='user_id',
    incremental_strategy='delete+insert',
    indexes=[{'columns': ['user_id'], 'unique': True},
             {'columns': ['first_post_on']}]
) }}

{% set settles_after_days = 90 %}

with joined as (
    select user_id, cohort_at
    from {{ ref('dim_member') }}
    where cohort_at is not null
),

first_post as (
    select
        f.user_id,
        f.posted_at::date as first_post_on,
        coalesce(f.posted_at < j.cohort_at + interval '30 days', false) as posted_within_30d_of_joining
    from {{ ref('fct_first_post') }} f
    left join joined j on j.user_id = f.user_id
    {% if is_incremental() %}
    where f.posted_at::date > current_date - {{ settles_after_days + 1 }}
       or not exists (select 1 from {{ this }} t where t.user_id = f.user_id)
    {% endif %}
),

active as (
    select
        user_id,
        window_start as active_date
    from {{ ref('fct_member_activity') }}
    where coalesce(days_active, 0) > 0
),

covered as (
    select distinct window_start as day
    from {{ ref('fct_member_activity') }}
),

coverage as (
    select
        w.first_post_on,
        count(*) filter (
            where c.day between w.first_post_on + 23 and w.first_post_on + 30
        ) > 0 as day_30_covered,
        count(*) filter (
            where c.day between w.first_post_on + 83 and w.first_post_on + 90
        ) > 0 and count(*) filter (
            where c.day between w.first_post_on + 23 and w.first_post_on + 30
        ) > 0 as day_90_covered,
        count(*) filter (
            where c.day between w.first_post_on and w.first_post_on + 14
        ) = 15 as visits_knowable
    from (select distinct first_post_on from first_post) w
    left join covered c on c.day between w.first_post_on and w.first_post_on + 90
    group by w.first_post_on
),

visits as (
    select
        f.user_id,
        f.first_post_on,
        a.active_date,
        row_number() over (partition by f.user_id order by a.active_date) as visit_number
    from first_post f
    inner join active a on a.user_id = f.user_id and a.active_date >= f.first_post_on
),

per_member as (
    select
        f.user_id,
        f.first_post_on,
        f.posted_within_30d_of_joining,
        coalesce(bool_or(
            v.active_date between f.first_post_on + 23 and f.first_post_on + 30
        ), false) as retained_day_30,
        coalesce(bool_or(
            v.active_date between f.first_post_on + 83 and f.first_post_on + 90
        ), false) and coalesce(bool_or(
            v.active_date between f.first_post_on + 23 and f.first_post_on + 30
        ), false) as retained_day_90,
        coalesce(bool_or(
            v.visit_number = 2 and v.active_date <= f.first_post_on + 1
        ), false) as returned_next_day,
        coalesce(bool_or(
            v.visit_number = 3 and v.active_date <= f.first_post_on + 7
        ), false) as third_visit_in_7_days,
        coalesce(bool_or(
            v.visit_number = 4 and v.active_date <= f.first_post_on + 14
        ), false) as fourth_visit_in_14_days
    from first_post f
    left join visits v on v.user_id = f.user_id
    group by f.user_id, f.first_post_on, f.posted_within_30d_of_joining
)

select
    m.user_id,
    m.first_post_on,
    m.posted_within_30d_of_joining,
    m.retained_day_30,
    m.retained_day_90,
    m.returned_next_day,
    m.third_visit_in_7_days,
    m.fourth_visit_in_14_days,
    c.day_30_covered,
    c.day_90_covered,
    c.visits_knowable
from per_member m
inner join coverage c on c.first_post_on = m.first_post_on
