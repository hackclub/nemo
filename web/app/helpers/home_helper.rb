module HomeHelper
  CHART_SERIES_A = "#1c7fcb".freeze
  CHART_SERIES_B = "#cc6608".freeze
  CHART_RATIO_LINE = "#454e58".freeze
  MIN_SAMPLE = 20

  def growth_cohort_status(row)
    return "n/a" if row.last_created_on.nil?

    if row.month == Date.current.beginning_of_month
      "#{row.last_created_on.day} of #{row.month.end_of_month.day} days"
    elsif row.claim_rate_30d_final_on > Date.current
      "final #{row.claim_rate_30d_final_on.strftime("%b %-d")}"
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
      borderColor: CHART_RATIO_LINE,
      backgroundColor: CHART_RATIO_LINE,
      borderWidth: 2,
      pointRadius: 0,
      pointHitRadius: 8,
      tension: 0,
      order: 0
    }
  end
end
