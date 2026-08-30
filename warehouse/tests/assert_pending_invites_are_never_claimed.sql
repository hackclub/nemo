select user_id
from {{ ref('dim_member') }}
where invite_pending
  and is_claimed
