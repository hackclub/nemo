module HomeHelper
  MIN_SAMPLE = 20

  def growth_cohort_status(row)
    return "n/a" if row.last_created_on.nil?

    if row.month == Date.current.beginning_of_month
      "#{row.last_created_on.day} of #{row.month.end_of_month.day} days"
    elsif row.claim_rate_30d_final_on > Date.current
      "matures #{row.claim_rate_30d_final_on.strftime("%b %-d")}"
    else
      "mature"
    end
  end

  ACTIVITY_GRANULARITIES = { "daily" => "daily", "monthly" => "monthly" }.freeze

  def activity_granularity(value)
    ACTIVITY_GRANULARITIES.fetch(value.to_s, "daily")
  end

  def activity_series(rows, granularity)
    if granularity == "monthly"
      {
        labels: rows.map { |r| r.month.strftime("%b %Y") },
        tick_every: 1,
        span: "#{rows.size} months",
        people: rows.map(&:active_users_28d),
        people_label: "active in last 28 days",
        posted: rows.map(&:writers_count_28d),
        posted_label: "posted in last 28 days",
        posted_share: rows.map { |r| share_pct(r.writers_count_28d, r.active_users_28d) },
        messages: rows.map(&:channel_messages),
        public_share: rows.map { |r| share_pct(r.public_channel_messages, r.channel_messages) }
      }
    else
      {
        labels: rows.map { |r| r.ds.strftime("%b %d") },
        tick_every: 15,
        span: "#{rows.size} days",
        people: rows.map(&:active_users_1d),
        people_label: "active",
        posted: rows.map(&:writers_count_1d),
        posted_label: "posted",
        posted_share: rows.map { |r| share_pct(r.writers_count_1d, r.active_users_1d) },
        messages: rows.map(&:channel_messages_1d),
        public_share: rows.map { |r| share_pct(r.chats_channels_count_1d, r.channel_messages_1d) }
      }
    end
  end

  STALE_AFTER_DAYS = 2

  def stat_delta(current, prior)
    return nil if current.nil? || prior.nil? || prior.to_f.zero?

    ((current.to_f - prior.to_f) / prior.to_f * 100).round(1)
  end

  def delta_chip(current, prior)
    pct = stat_delta(current, prior)
    return nil if pct.nil? || pct.abs < 0.05

    arrow = pct.positive? ? "↑" : "↓"
    style = pct.positive? ? "chip chip-good" : "chip chip-warn"
    tag.span("#{arrow} #{number_to_percentage(pct.abs, precision: 1)}", class: style)
  end

  def share_chip(numerator, denominator)
    return nil if denominator.nil? || denominator.to_i.zero?

    tag.span(number_to_percentage(numerator.to_f / denominator * 100, precision: 1), class: "chip chip-off")
  end

  def rate_chip(pct, label = nil)
    style = if pct >= 60 then "chip chip-good"
    elsif pct >= 30 then "chip chip-off"
    else "chip chip-warn"
    end
    text = number_to_percentage(pct, precision: 1)
    tag.span(label ? "#{text} #{label}" : text, class: style)
  end

  def incomplete_chip(*reasons)
    reasons = reasons.compact
    return nil if reasons.empty?

    tag.span("not complete", class: "chip chip-off", title: reasons.join("; "))
  end

  def reply_wait(seconds)
    return "n/a" if seconds.nil?

    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 90

    minutes = seconds / 60
    return "#{minutes} min" if minutes < 90

    hours = minutes / 60.0
    return format("%.1f h", hours) if hours < 48

    format("%.1f d", hours / 24)
  end

  def as_of_badge(ds)
    return tag.span("no data loaded", class: "chip chip-warn") if ds.nil?

    age = (Date.current - ds).to_i
    behind = age.zero? ? "today" : "#{pluralize(age, "day")} behind"
    label = "data as of #{ds.strftime("%b %-d, %Y")} · #{behind}"
    return tag.span(label, class: "head-meta") if age <= STALE_AFTER_DAYS

    tag.span(label, class: "chip chip-warn")
  end

  def share_pct(numerator, denominator)
    return 0.0 if denominator.nil? || denominator.to_i.zero?

    ((numerator.to_f / denominator) * 100).round(1)
  end

  def ratio_line_dataset(label, data)
    {
      label: label,
      data: data,
      type: "line",
      yAxisID: "y1",
      borderWidth: 2,
      pointRadius: 0,
      pointHitRadius: 8,
      tension: 0,
      order: 0
    }
  end
end
