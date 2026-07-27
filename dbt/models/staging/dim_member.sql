select
    user_id,
    account_type,
    is_guest,
    account_created,
    claimed_at,
    deactivated_at,
    claimed_at is not null or coalesce(claimed_no_date, false) as is_claimed,
    coalesce(is_bot, false) as is_bot
from {{ source('raw', 'member_dim') }}
