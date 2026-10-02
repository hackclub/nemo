{{ config(materialized='view') }}

select *
from {{ ref('fct_member_day') }}
