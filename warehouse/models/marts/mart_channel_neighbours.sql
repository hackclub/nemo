{% set kept = 8 %}
{% set min_shared = 3 %}
{% set busiest_member = 60 %}
{% set months_back = 3 %}

{{ config(indexes=[
    {'columns': ['channel_id', 'neighbour_rank'], 'unique': True},
    {'columns': ['channel_id']}
]) }}

with edge as (
    select max(ds) as last_day
    from {{ ref('mart_channel_day') }}
),

span as (
    select
        date_trunc('month', last_day - interval '{{ months_back - 1 }} months')::date as window_start,
        last_day as window_end
    from edge
),

posters as (
    select distinct p.channel_id, p.user_id
    from {{ ref('mart_channel_person') }} p
    cross join span s
    where p.messages > 0
      and p.month >= s.window_start
),

narrow as (
    select user_id
    from posters
    group by user_id
    having count(*) <= {{ busiest_member }}
),

kept_posters as (
    select p.channel_id, p.user_id
    from posters p
    inner join narrow n on n.user_id = p.user_id
),

sized as (
    select channel_id, count(*)::integer as posters
    from kept_posters
    group by 1
),

shared as (
    select
        a.channel_id,
        b.channel_id as neighbour_id,
        count(*)::integer as shared_posters
    from kept_posters a
    inner join kept_posters b
        on b.user_id = a.user_id
       and b.channel_id <> a.channel_id
    group by 1, 2
    having count(*) >= {{ min_shared }}
),

scored as (
    select
        s.channel_id,
        s.neighbour_id,
        s.shared_posters,
        mine.posters as posters,
        theirs.posters as neighbour_posters,
        round(s.shared_posters::numeric
            / nullif(mine.posters + theirs.posters - s.shared_posters, 0), 4) as jaccard
    from shared s
    inner join sized mine on mine.channel_id = s.channel_id
    inner join sized theirs on theirs.channel_id = s.neighbour_id
),

ranked as (
    select
        *,
        row_number() over (
            partition by channel_id order by jaccard desc, shared_posters desc, neighbour_id
        )::integer as neighbour_rank
    from scored
)

select
    r.channel_id,
    r.neighbour_id,
    c.name as neighbour_name,
    c.archived as neighbour_archived,
    r.neighbour_rank,
    r.shared_posters,
    r.posters,
    r.neighbour_posters,
    r.jaccard,
    e.window_start,
    e.window_end,
    'v2' as metric_version
from ranked r
inner join {{ ref('dim_channel') }} c on c.channel_id = r.neighbour_id
cross join span e
where r.neighbour_rank <= {{ kept }}
