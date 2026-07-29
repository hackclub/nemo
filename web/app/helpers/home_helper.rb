module HomeHelper
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
end
