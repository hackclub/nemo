select
    user_id,
    account_type,
    is_guest,
    account_created,
    claimed_at,
    deactivated_at
from {{ source('raw', 'member_dim') }}
