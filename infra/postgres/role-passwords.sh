#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
ALTER ROLE pipeline_writer PASSWORD '${PIPELINE_DB_PASSWORD}';
ALTER ROLE dbt_owner PASSWORD '${DBT_DB_PASSWORD}';
ALTER ROLE rails_app PASSWORD '${RAILS_DB_PASSWORD}';
SQL
