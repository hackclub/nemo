module AuditHelper
  WINDOWS = { "Last 24 hours" => "24h", "Last 7 days" => "7d", "Last 30 days" => "30d" }.freeze
  DOERS = { "A person" => "human", "nemo" => "nemo", "Nobody" => "nobody" }.freeze
  FIRST_DAY = Fd::AuditQuery::FIRST_DAY
  CHEVRON = "m6 9 6 6 6-6".freeze

  def audit_stamp(at)
    local = at.in_time_zone
    tag.time(datetime: local.iso8601, title: at.utc.strftime("%-d %b %Y %H:%M:%S UTC")) do
      safe_join([local.strftime("%-d %b"), " ", tag.span(local.strftime("%H:%M"), class: "audit-clock")])
    end
  end

  def audit_group_value(group, one)
    case group
    when "actor" then member_face(one.key)
    when "action" then tag.span(Fd::AuditCatalogue.action_label(one.key), class: "audit-verb")
    when "address" then tag.span(one.key, class: "mono")
    when "channel" then audit_channel(one.key)
    when "app" then one.name.presence || tag.span(one.key, class: "mono")
    end
  end

  def audit_pivots(query, row)
    query.pivots(row).reject { |one| one.kind == "channel" && !channels.named?(row.channel) }
  end

  PIVOT_ICON = "M3 4h18l-7 8.5V18l-4 2v-7.5z".freeze

  def pivot_icon
    tag.svg(tag.path(d: PIVOT_ICON), width: 13, height: 13, viewBox: "0 0 24 24", fill: "none",
      stroke: "currentColor", "stroke-width": 2, "stroke-linejoin": "round", "aria-hidden": true)
  end

  def audit_filter_trigger(key, value)
    safe_join([
      tag.span(key, class: "filter-key"),
      (tag.span(value, class: "filter-val") if value.present?),
      tag.svg(tag.path(d: CHEVRON), width: 11, height: 11, viewBox: "0 0 24 24", fill: "none",
        stroke: "currentColor", "stroke-width": 2.5, "aria-hidden": true)
    ].compact)
  end
end
