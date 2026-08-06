module Analytics
  class MartMonthlyCohorts < ApplicationRecord
    self.table_name = "analytics.mart_monthly_cohorts"
    self.primary_key = "cohort_month"

    def readonly?
      true
    end

    def complete?
      searched >= members
    end
  end
end
