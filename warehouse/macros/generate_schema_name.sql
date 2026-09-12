{#
    A full nightly build passes --vars '{"candidate_schema": "analytics_build"}' so every
    model lands in one isolated schema regardless of its configured custom schema, letting
    nightly_sync.py test the whole build before promoting it over the live schema. Without
    that var (ad-hoc runs, dev, the periodic partial refreshes) this falls back to dbt's own
    default naming so behaviour outside the nightly is unchanged.
#}
{% macro generate_schema_name(custom_schema_name, node) %}
    {%- set candidate = var('candidate_schema', none) -%}
    {%- if candidate is not none -%}
        {{ candidate }}
    {%- else -%}
        {{ generate_schema_name_for_env(custom_schema_name, node) }}
    {%- endif -%}
{% endmacro %}
