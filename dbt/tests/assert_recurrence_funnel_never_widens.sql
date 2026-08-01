select
    cohort_month,
    created_account,
    signed_in,
    sent_message,
    returned_next_day,
    third_visit_in_7_days,
    fourth_visit_in_14_days
from {{ ref('mart_onboarding_recurrence_funnel') }}
where signed_in > created_account
    or sent_message > signed_in
    or returned_next_day > sent_message
    or third_visit_in_7_days > returned_next_day
    or fourth_visit_in_14_days > third_visit_in_7_days
