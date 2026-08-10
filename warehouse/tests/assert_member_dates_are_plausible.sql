select
    user_id,
    account_created_verified,
    claimed_at,
    deactivated_at
from {{ ref('dim_member') }}
where account_created_verified > now()
    or claimed_at > now()
    or deactivated_at > now()
