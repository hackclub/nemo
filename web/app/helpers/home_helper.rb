module HomeHelper
  MIN_SAMPLE = 20
  GROWTH_SPANS = [6, 12, 24].freeze
  DEFAULT_GROWTH_SPAN = 6

  def window_note(from, to)
    return nil if from.nil? || to.nil?

    return to.strftime("%-d %b %Y") if from == to

    same_year = from.year == to.year
    "#{from.strftime(same_year ? '%-d %b' : '%-d %b %Y')} to #{to.strftime('%-d %b %Y')}"
  end

  OVERVIEW_SPANS = {
    "7d" => { label: "7 days", days: 7, granularity: "daily" },
    "28d" => { label: "28 days", days: 28, granularity: "daily" },
    "90d" => { label: "90 days", days: 90, granularity: "daily" },
    "12m" => { label: "12 months", months: 12, granularity: "monthly" }
  }.freeze
  DEFAULT_OVERVIEW_SPAN = "28d".freeze

  def overview_span(value)
    OVERVIEW_SPANS.key?(value.to_s) ? value.to_s : DEFAULT_OVERVIEW_SPAN
  end

  def span_of(key)
    OVERVIEW_SPANS.fetch(overview_span(key))
  end

  def activity_series(rows, granularity)
    if granularity == "monthly"
      {
        labels: rows.map { |r| r.month.strftime("%b %Y") },
        days: false,
        span: "#{rows.size} months",
        partial: rows.each_with_index.filter_map { |r, i| i unless r.is_complete },
        posted: rows.map(&:writers_count_28d),
        posted_label: "posted",
        silent: rows.map { |r| r.active_users_28d.to_i - r.writers_count_28d.to_i },
        silent_label: "active, did not post",
        posted_share: rows.map { |r| share_pct(r.writers_count_28d, r.active_users_28d) },
        public: rows.map(&:public_channel_messages),
        public_label: "public channels",
        private: rows.map { |r| r.channel_messages.to_i - r.public_channel_messages.to_i },
        private_label: "private channels",
        public_share: rows.map { |r| share_pct(r.public_channel_messages, r.channel_messages) }
      }
    else
      {
        labels: rows.map { |r| r.ds.iso8601 },
        days: true,
        span: "#{rows.size} days",
        partial: [],
        posted: rows.map(&:writers_count_1d),
        posted_label: "posted",
        silent: rows.map { |r| r.active_users_1d.to_i - r.writers_count_1d.to_i },
        silent_label: "active, did not post",
        posted_share: rows.map { |r| share_pct(r.writers_count_1d, r.active_users_1d) },
        public: rows.map(&:chats_channels_count_1d),
        public_label: "public channels",
        private: rows.map { |r| r.channel_messages_1d.to_i - r.chats_channels_count_1d.to_i },
        private_label: "private channels",
        public_share: rows.map { |r| share_pct(r.chats_channels_count_1d, r.channel_messages_1d) }
      }
    end
  end

  def stat_delta(current, prior)
    return nil if current.nil? || prior.nil? || prior.to_f.zero?

    ((current.to_f - prior.to_f) / prior.to_f * 100).round(1)
  end

  def delta_chip(current, prior)
    pct = stat_delta(current, prior)
    return nil if pct.nil? || pct.abs < 0.05

    arrow = pct.positive? ? "↑" : "↓"
    style = pct.positive? ? "delta-up" : "delta-down"
    tag.span("#{arrow} #{number_to_percentage(pct.abs, precision: 1)}", class: style)
  end

  def share_chip(numerator, denominator)
    return nil if denominator.nil? || denominator.to_i.zero?

    tag.span(number_to_percentage(numerator.to_f / denominator * 100, precision: 1),
      class: "delta-share")
  end

  REPLY_CLASS_LABEL = {
    "fast" => "under 1 h",
    "slow" => "over 1 h",
    "none" => "no member reply"
  }.freeze

  def reply_class_label(reply_class)
    REPLY_CLASS_LABEL.fetch(reply_class, reply_class)
  end

  def rate_chip(pct, label = nil)
    text = number_to_percentage(pct, precision: 1)
    tag.span(label ? "#{text} #{label}" : text, class: "tn")
  end

  def retention_cell(rate)
    return tag.span("n/a", class: "sub2") if rate.nil?

    number_to_percentage((rate.to_f * 100).round(1), precision: 1)
  end

  def incomplete_chip(*reasons)
    reasons = reasons.compact
    return nil if reasons.empty?

    tag.span("not complete", class: "chip chip-off", title: reasons.join("; "))
  end

  def reply_wait(seconds)
    return tag.span("n/a", class: "sub2") if seconds.nil?

    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 90

    minutes = seconds / 60
    return "#{minutes} min" if minutes < 90

    hours = minutes / 60.0
    return format("%.1f h", hours) if hours < 48

    format("%.1f d", hours / 24)
  end

  def share_pct(numerator, denominator)
    return nil if denominator.nil? || denominator.to_i.zero? || numerator.nil?

    ((numerator.to_f / denominator) * 100).round(1)
  end

  def rate_cell(numerator, denominator, precision: 1)
    pct = share_pct(numerator, denominator)
    return tag.span("n/a", class: "sub2") if pct.nil?

    tag.span(class: "two-line", title: "#{number_with_delimiter(numerator)} of " \
      "#{number_with_delimiter(denominator)}") do
      concat tag.b(number_to_percentage(pct, precision: precision))
      concat tag.span("#{number_with_delimiter(numerator)}/#{number_with_delimiter(denominator)}")
    end
  end

  HEAT_STEPS = 6

  def heat_step(value, peak)
    return 0 if value.nil? || peak.nil? || peak.to_f <= 0

    [[(value.to_f / peak * (HEAT_STEPS - 1)).round, 0].max, HEAT_STEPS - 1].min
  end

  def lifecycle_cell(row, stage, peak)
    value = row.public_send(stage[:key])
    return heat_cell(value, peak, lifecycle_reason(row, stage)) if value

    if lifecycle_open?(row, stage)
      tag.span("pending", class: "lg-cell lg-open",
        title: "#{lifecycle_reason(row, stage)}, closes " \
               "#{lifecycle_closes(row, stage).strftime('%-d %b %Y')}")
    else
      tag.span("n/a", class: "lg-cell lg-none", title: lifecycle_reason(row, stage))
    end
  end

  def heat_cell(value, peak, title)
    tag.span(number_to_percentage(value.to_f * 100, precision: 1),
      class: "lg-cell lg-h#{heat_step(value, peak)}", title: title)
  end

  def lifecycle_open?(row, stage)
    case stage[:key]
    when :claim_rate_30d then false
    when :posted_rate_30d then row.searched.to_i.positive?
    when :rate_30, :rate_90 then row.searched.to_i.positive?
    end
  end

  def lifecycle_closes(row, stage)
    row.closes_on(stage[:key])
  end

  def lifecycle_reason(row, stage)
    case stage[:key]
    when :claim_rate_30d
      if row.claim_rate_30d
        "#{number_with_delimiter(row.claimed_within_30d)} of " \
          "#{number_with_delimiter(row.invited)} created accounts signed in within 30 days"
      else
        "#{number_with_delimiter(row.invited.to_i - row.claimed.to_i)} accounts carry no claim " \
          "date, so a 30-day rate cannot be published"
      end
    when :posted_rate_30d
      if row.searched.to_i.positive?
        "#{number_with_delimiter(row.posted_30d)} of #{number_with_delimiter(row.searched)} " \
          "searched members posted inside their first 30 days"
      else
        "no searched message history for this cohort, so posting is unobservable"
      end
    when :rate_30
      lifecycle_window_reason(row.retained_30, row.measured_30, row.searched, 30)
    when :rate_90
      lifecycle_window_reason(row.retained_90, row.measured_90, row.searched, 90)
    end
  end

  def lifecycle_window_reason(hits, measured, searched, day)
    return "no searched message history for this cohort" if searched.to_i.zero?
    if measured.to_i.zero?
      return "the day-#{day} window has not closed for enough of this cohort"
    end

    "#{number_with_delimiter(hits)} of #{number_with_delimiter(measured)} first posters were " \
      "active in the 7 days ending on day #{day}"
  end

  BAND_TOP = { 0 => 0, 1 => 1, 2 => 4, 3 => 16, 4 => 64, 5 => 256, 6 => 1024, 7 => 4096 }.freeze

  def band_split(value, bands, label)
    return nil if value.nil?

    at = bands.index { |b| BAND_TOP.fetch(b.band_order, Float::INFINITY) >= value.to_i }
    return nil if at.nil? || at >= bands.size - 1

    { after: at, label: "#{label} #{number_with_delimiter(value)}" }
  end

  def wilson_bounds(hits, sample)
    return nil if sample.nil? || sample.to_i.zero?

    z = 1.96
    p = hits.to_f / sample
    d = 1 + (z**2 / sample)
    centre = (p + (z**2 / (2.0 * sample))) / d
    margin = z * Math.sqrt((p * (1 - p) / sample) + (z**2 / (4.0 * sample**2))) / d
    [[centre - margin, 0].max * 100, [centre + margin, 1].min * 100]
  end
end
