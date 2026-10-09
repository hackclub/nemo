module AuditHelper
  WINDOWS = { "Last 24 hours" => 1, "Last 7 days" => 7, "Last 30 days" => 30 }.freeze
  DOERS = { "A person" => "human", "nemo" => "nemo", "Nobody" => "nobody" }.freeze
  FIRST_DAY = Date.new(2025, 11, 1)
  CHEVRON = "m6 9 6 6 6-6".freeze

  def audit_filter_trigger(key, value)
    safe_join([
      tag.span(key, class: "filter-key"),
      (tag.span(value, class: "filter-val") if value.present?),
      tag.svg(tag.path(d: CHEVRON), width: 11, height: 11, viewBox: "0 0 24 24", fill: "none",
        stroke: "currentColor", "stroke-width": 2.5, "aria-hidden": true)
    ].compact)
  end
end
