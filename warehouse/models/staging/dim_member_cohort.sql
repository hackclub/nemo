{{ config(materialized='table', indexes=[{'columns': ['user_id'], 'unique': true}]) }}

select
    user_id,
    cohort_at
from {{ ref('dim_member') }}
