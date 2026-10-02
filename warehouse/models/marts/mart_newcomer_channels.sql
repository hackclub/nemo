{% set cohort_days = 30 %}
{% set return_days = 30 %}

{{ config(indexes=[{'columns': ['cohort_key', 'channel_id'], 'unique': True},
                   {'columns': ['cohort_key']}]) }}

with edge as (
    select max(claimed_at)::date as claimed_edge
    from {{ ref('dim_member') }}
),

watermark as (
    select max(ds) as observed_through
    from {{ ref('fct_member_day') }}
),

member as (
    select
        d.user_id,
        d.claimed_at::date as claimed_on,
        date_trunc('month', d.claimed_at)::date as claim_month,
        m.user_id is not null as read
    from {{ ref('dim_member') }} d
    left join (
        select distinct user_id from {{ ref('fct_member_channel_membership') }}
    ) m on m.user_id = d.user_id
    where d.claimed_at is not null
      and not d.is_bot
      and not d.is_deleted
      and not d.invite_pending
),

cohort as (
    select
        'last30' as cohort_key,
        0 as cohort_order,
        e.claimed_edge - {{ cohort_days }} as cohort_start,
        e.claimed_edge as cohort_end,
        m.user_id,
        m.read
    from member m
    cross join edge e
    where m.claimed_on >= e.claimed_edge - {{ cohort_days }}

    union all

    select
        to_char(m.claim_month, 'YYYY-MM'),
        1,
        m.claim_month,
        (m.claim_month + interval '1 month' - interval '1 day')::date,
        m.user_id,
        m.read
    from member m
),

reach as (
    select
        c.cohort_key,
        min(c.cohort_order) as cohort_order,
        min(c.cohort_start) as cohort_start,
        max(c.cohort_end) as cohort_end,
        count(*) as cohort_size,
        count(*) as searched_of_cohort,
        count(*) filter (where c.read) as read_of_cohort,
        max(c.cohort_end) + {{ return_days }} <= w.observed_through as mature
    from cohort c
    cross join watermark w
    group by c.cohort_key, w.observed_through
),

returners as (
    select
        user_id,
        count(*) filter (where day_offset between 1 and {{ return_days }}) > 0 as came_back
    from {{ ref('fct_member_day') }}
    group by user_id
),

posted as (
    select
        c.cohort_key,
        f.channel_id,
        count(distinct f.user_id) as newcomers_posting,
        count(distinct f.user_id) filter (where f.returned) as newcomers_returning,
        count(distinct f.user_id) filter (where r.came_back)
            as newcomers_returning_anywhere,
        sum(f.messages) as newcomer_messages
    from {{ ref('fct_member_channel') }} f
    inner join cohort c on c.user_id = f.user_id
    left join returners r on r.user_id = f.user_id
    group by 1, 2
),

joined as (
    select
        c.cohort_key,
        m.channel_id,
        count(distinct m.user_id) as newcomers_joined
    from {{ ref('fct_member_channel_membership') }} m
    inner join cohort c on c.user_id = m.user_id
    group by 1, 2
),

landed as (
    select
        c.cohort_key,
        f.channel_id,
        count(*) as newcomer_first_posts
    from {{ ref('fct_first_post') }} f
    inner join cohort c on c.user_id = f.user_id
    where f.channel_id is not null
    group by 1, 2
),

whole as (
    select
        channel_id,
        window_start,
        window_end,
        messages_posted_by_members,
        members_who_posted,
        members_who_viewed
    from {{ ref('mart_channel_range') }}
),

baseline as (
    select cohort_key, coalesce(sum(newcomer_messages), 0) as newcomer_total
    from posted
    group by 1
),

workspace as (
    select coalesce(sum(messages_posted_by_members), 0) as workspace_total
    from whole
),

together as (
    select
        coalesce(p.cohort_key, j.cohort_key, l.cohort_key) as cohort_key,
        coalesce(p.channel_id, j.channel_id, l.channel_id) as channel_id,
        coalesce(p.newcomers_posting, 0) as newcomers_posting,
        coalesce(p.newcomers_returning, 0) as newcomers_returning,
        coalesce(p.newcomers_returning_anywhere, 0) as newcomers_returning_anywhere,
        coalesce(p.newcomer_messages, 0) as newcomer_messages,
        coalesce(j.newcomers_joined, 0) as newcomers_joined,
        coalesce(l.newcomer_first_posts, 0) as newcomer_first_posts
    from posted p
    full outer join joined j
        on j.cohort_key = p.cohort_key and j.channel_id = p.channel_id
    full outer join landed l
        on l.cohort_key = coalesce(p.cohort_key, j.cohort_key)
        and l.channel_id = coalesce(p.channel_id, j.channel_id)
)

select
    t.cohort_key,
    r.cohort_order,
    t.channel_id,
    c.name,
    t.newcomers_posting,
    t.newcomers_returning,
    t.newcomers_returning_anywhere,
    t.newcomer_messages,
    t.newcomers_joined,
    t.newcomer_first_posts,
    w.messages_posted_by_members as channel_messages,
    w.members_who_posted as channel_posters,
    w.members_who_viewed as channel_viewers,
    case
        when coalesce(w.messages_posted_by_members, 0) > 0
        then round(t.newcomer_messages::numeric / w.messages_posted_by_members, 4)
    end as newcomer_message_share,
    case
        when r.read_of_cohort > 0
        then round(t.newcomers_joined::numeric / r.read_of_cohort, 4)
    end as joined_share,
    case
        when t.newcomers_posting > 0
        then round(t.newcomers_returning::numeric / t.newcomers_posting, 4)
    end as returning_share,
    case
        when t.newcomers_posting > 0
        then round(t.newcomers_returning_anywhere::numeric / t.newcomers_posting, 4)
    end as returning_anywhere_share,
    case
        when b.newcomer_total > 0
             and s.workspace_total > 0
             and coalesce(w.messages_posted_by_members, 0) > 0
        then round(
            (t.newcomer_messages::numeric / b.newcomer_total)
            / (w.messages_posted_by_members::numeric / s.workspace_total), 2)
    end as newcomer_lift,
    r.cohort_size,
    r.searched_of_cohort,
    r.read_of_cohort,
    r.cohort_start,
    r.cohort_end,
    r.mature,
    {{ return_days }}::integer as return_window_days,
    w.window_start,
    w.window_end,
    'v5' as metric_version
from together t
inner join reach r on r.cohort_key = t.cohort_key
inner join baseline b on b.cohort_key = t.cohort_key
cross join workspace s
inner join {{ ref('dim_channel') }} c on c.channel_id = t.channel_id
left join whole w on w.channel_id = t.channel_id
