{% set months_kept = 13 %}

{{ config(indexes=[
    {'columns': ['channel_id', 'month', 'user_id'], 'unique': True},
    {'columns': ['channel_id', 'month', 'channel_rank']}
]) }}

with edge as (
    select max(ds) as last_day
    from {{ ref('mart_channel_day') }}
),

span as (
    select
        date_trunc('month', last_day - interval '{{ months_kept - 1 }} months')::date as floor_month,
        last_day
    from edge
),

said as (
    select
        m.channel_id,
        date_trunc('month', m.posted_at at time zone 'UTC')::date as month,
        m.author_id as user_id,
        count(*)::integer as messages,
        count(*) filter (where m.is_reply)::integer as replies,
        count(*) filter (where m.is_question)::integer as questions,
        count(distinct (m.posted_at at time zone 'UTC')::date)::integer as days_posted,
        min(m.posted_at) as first_at,
        max(m.posted_at) as last_at
    from {{ ref('fct_message') }} m
    cross join span s
    where m.author_kind = 'member'
      and m.author_id is not null
      and coalesce(m.subtype, '') <> 'channel_join'
      and (m.posted_at at time zone 'UTC')::date >= s.floor_month
    group by 1, 2, 3
),

whole as (
    select
        channel_id,
        month,
        sum(messages)::bigint as channel_messages,
        count(*)::integer as channel_posters
    from said
    group by 1, 2
),

tenured as (
    select
        d.user_id,
        c.cohort_at::date as joined_on
    from {{ ref('dim_member') }} d
    left join {{ ref('dim_member_cohort') }} c on c.user_id = d.user_id
    where not d.is_bot
),

edges as (
    select
        month,
        (month + interval '1 month' - interval '1 day')::date as month_end
    from (select distinct month from said) m
)

select
    p.channel_id,
    p.month,
    p.user_id,
    p.messages,
    p.replies,
    p.questions,
    p.days_posted,
    p.first_at,
    p.last_at,
    case when t.joined_on is not null then (e.month_end - t.joined_on)::integer end as tenure_days,
    case
        when t.joined_on is null then 'unknown'
        when (e.month_end - t.joined_on) < 90 then 'under_90d'
        when (e.month_end - t.joined_on) < 365 then 'under_1y'
        when (e.month_end - t.joined_on) < 1095 then 'under_3y'
        else 'over_3y'
    end as tenure_band,
    row_number() over (
        partition by p.channel_id, p.month order by p.messages desc, p.user_id
    )::integer as channel_rank,
    round(100.0 * p.messages / nullif(w.channel_messages, 0), 4) as share_of_channel,
    w.channel_messages,
    w.channel_posters,
    e.month_end,
    'v2' as metric_version
from said p
inner join whole w on w.channel_id = p.channel_id and w.month = p.month
inner join edges e on e.month = p.month
inner join tenured t on t.user_id = p.user_id
