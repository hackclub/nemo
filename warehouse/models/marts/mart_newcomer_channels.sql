{% set cohort_days = 30 %}

with edge as (
    select max(claimed_at)::date as claimed_edge
    from {{ ref('dim_member') }}
),

cohort as (
    select
        d.user_id,
        w.messages_searched_at is not null as searched,
        w.membership_read_at is not null as read
    from {{ ref('dim_member') }} d
    cross join edge
    left join {{ source('raw', 'member_channel_walk') }} w on w.user_id = d.user_id
    where d.claimed_at >= edge.claimed_edge - {{ cohort_days }}
      and not d.is_bot
      and not d.is_deleted
      and not d.invite_pending
),

reach as (
    select
        count(*) as cohort_size,
        count(*) filter (where searched) as searched_of_cohort,
        count(*) filter (where read) as read_of_cohort
    from cohort
),

posted as (
    select
        f.channel_id,
        count(distinct f.user_id) as newcomers_posting,
        count(distinct f.user_id) filter (where f.returned) as newcomers_returning,
        sum(f.messages) as newcomer_messages
    from {{ ref('fct_member_channel') }} f
    join cohort c on c.user_id = f.user_id
    group by 1
),

joined as (
    select
        m.channel_id,
        count(distinct m.user_id) as newcomers_joined
    from {{ ref('fct_member_channel_membership') }} m
    join cohort c on c.user_id = m.user_id
    group by 1
),

landed as (
    select
        h.first_post_channel as channel_id,
        count(*) as newcomer_first_posts
    from {{ ref('fct_member_history') }} h
    join cohort c on c.user_id = h.user_id
    where h.first_post_channel is not null
    group by 1
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
    select
        (select coalesce(sum(newcomer_messages), 0) from posted) as newcomer_total,
        (select coalesce(sum(messages_posted_by_members), 0) from whole) as workspace_total
),

together as (
    select
        coalesce(p.channel_id, j.channel_id, l.channel_id) as channel_id,
        coalesce(p.newcomers_posting, 0) as newcomers_posting,
        coalesce(p.newcomers_returning, 0) as newcomers_returning,
        coalesce(p.newcomer_messages, 0) as newcomer_messages,
        coalesce(j.newcomers_joined, 0) as newcomers_joined,
        coalesce(l.newcomer_first_posts, 0) as newcomer_first_posts
    from posted p
    full outer join joined j on j.channel_id = p.channel_id
    full outer join landed l on l.channel_id = coalesce(p.channel_id, j.channel_id)
)

select
    t.channel_id,
    c.name,
    t.newcomers_posting,
    t.newcomers_returning,
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
        when b.newcomer_total > 0
             and b.workspace_total > 0
             and coalesce(w.messages_posted_by_members, 0) > 0
        then round(
            (t.newcomer_messages::numeric / b.newcomer_total)
            / (w.messages_posted_by_members::numeric / b.workspace_total), 2)
    end as newcomer_lift,
    r.cohort_size,
    r.searched_of_cohort,
    r.read_of_cohort,
    (select claimed_edge - {{ cohort_days }} from edge) as cohort_start,
    (select claimed_edge from edge) as cohort_end,
    w.window_start,
    w.window_end,
    'v1' as metric_version
from together t
cross join reach r
cross join baseline b
join {{ ref('dim_channel') }} c on c.channel_id = t.channel_id
left join whole w on w.channel_id = t.channel_id
where not coalesce(c.archived, false)
order by t.newcomers_posting desc, t.newcomer_messages desc
