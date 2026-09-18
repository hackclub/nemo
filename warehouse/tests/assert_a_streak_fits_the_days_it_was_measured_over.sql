select
    user_id,
    current_days,
    current_from,
    current_to,
    longest_days,
    longest_from,
    longest_to,
    measured_through
from {{ ref('mart_member_streak') }}
where longest_days > (longest_to - longest_from) + 1
    or current_days > coalesce((current_to - current_from) + 1, 0)
    or current_days > longest_days
    or current_to > measured_through
    or (current_days > 0 and current_to < measured_through - 1)
