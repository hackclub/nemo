select *
from {{ ref('fct_message') }}
where author_kind = 'member'
  and author_id is not null
  and coalesce(subtype, '') <> 'channel_join'
