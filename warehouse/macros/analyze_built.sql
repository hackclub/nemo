{% macro analyze_built() %}
  {% if execute %}
    {% for result in results %}
      {% if result.node.resource_type == 'model' and result.status == 'success' %}
        {% do run_query("ANALYZE " ~ result.node.relation_name) %}
      {% endif %}
    {% endfor %}
  {% endif %}
{% endmacro %}
