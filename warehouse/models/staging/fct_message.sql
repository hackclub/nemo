{{ config(
    materialized='incremental',
    unique_key=['channel_id', 'ts'],
    incremental_strategy='delete+insert',
    on_schema_change='fail',
    indexes=[{'columns': ['channel_id', 'ts'], 'unique': True},
             {'columns': ['posted_at']}],
    post_hook="delete from {{ this }} t using archive.message m where m.channel_id = t.channel_id and m.ts = t.ts and m.deleted_at is not null"
) }}

{% set lookback_hours = 2 %}

select
    channel_id,
    ts,
    author_id,
    author_kind,
    bot_id,
    app_id,
    parent_user_id,
    subtype,
    thread_root_ts,
    is_reply,
    is_broadcast,
    posted_at,
    edited_at,
    reply_count,
    reply_users_count,
    latest_reply_ts,
    reaction_count,
    reactor_count,
    file_count,
    text_length,
    mention_count,
    mentioned_ids,
    is_question,
    is_substantive,
    has_link,
    emoji_only,
    settled,
    first_seen_at as observed_at
from {{ source('archive', 'message') }}
where deleted_at is null
{% if is_incremental() %}
  and updated_at > (
      select coalesce(max(observed_at), '-infinity'::timestamptz)
           - interval '{{ lookback_hours }} hours'
      from {{ this }}
  )
{% endif %}
