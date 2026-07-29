module HomeHelper
  CHART_SERIES_A = "#1c7fcb".freeze
  CHART_SERIES_B = "#cc6608".freeze
  CHART_RATIO_LINE = "#454e58".freeze

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
