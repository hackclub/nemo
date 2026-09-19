select user_id, window_start, count(*) as rows_in
from {{ ref('fct_member_activity') }}
group by user_id, window_start
having count(*) > 1
