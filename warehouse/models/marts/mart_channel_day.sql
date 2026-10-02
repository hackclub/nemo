{{ config(indexes=[
    {'columns': ['channel_id', 'ds'], 'unique': True},
    {'columns': ['ds']}
]) }}

with counted as (
    select
        m.channel_id,
        (m.posted_at at time zone 'UTC')::date as ds,
        count(*)::integer as messages,
        count(*) filter (
            where m.author_kind = 'member'
              and m.author_id is not null
              and coalesce(m.subtype, '') <> 'channel_join'
        )::integer as member_messages,
        count(*) filter (where m.author_kind <> 'member')::integer as bot_messages,
        count(distinct m.author_id)::integer as authors,
        count(distinct m.author_id) filter (
            where m.author_kind = 'member'
        )::integer as member_authors,
        count(*) filter (where m.is_reply)::integer as thread_replies,
        count(*) filter (
            where not m.is_reply and coalesce(m.reply_count, 0) > 0
        )::integer as thread_roots,
        coalesce(sum(m.reply_count) filter (where not m.is_reply), 0)::integer as replies_on_roots,
        count(*) filter (where m.is_question)::integer as questions,
        count(*) filter (
            where m.is_question and coalesce(m.reply_count, 0) > 0
        )::integer as questions_with_replies,
        count(*) filter (where m.has_link)::integer as with_link,
        count(*) filter (where coalesce(m.file_count, 0) > 0)::integer as with_file,
        count(*) filter (where m.emoji_only)::integer as emoji_only,
        count(*) filter (where m.is_substantive)::integer as substantive,
        count(*) filter (where coalesce(m.mention_count, 0) > 0)::integer as with_mention,
        coalesce(sum(m.reaction_count), 0)::bigint as reactions,
        count(*) filter (where coalesce(m.reaction_count, 0) = 0)::integer as unreacted,
        coalesce(sum(m.text_length), 0)::bigint as text_length_total
    from {{ ref('fct_message') }} m
    group by 1, 2
)

select
    c.channel_id,
    c.ds,
    c.messages,
    c.member_messages,
    c.bot_messages,
    c.authors,
    c.member_authors,
    c.thread_replies,
    c.thread_roots,
    c.replies_on_roots,
    c.questions,
    c.questions_with_replies,
    c.with_link,
    c.with_file,
    c.emoji_only,
    c.substantive,
    c.with_mention,
    c.reactions,
    c.unreacted,
    c.text_length_total,
    'v1' as metric_version
from counted c
