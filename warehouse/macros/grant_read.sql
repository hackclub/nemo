{% macro grant_read(role) %}
do $do$
begin
    if exists (select 1 from pg_roles where rolname = '{{ role }}') then
        execute 'grant select on {{ this }} to {{ role }}';
    end if;
end
$do$
{% endmacro %}
