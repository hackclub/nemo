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

    def mature?
      cohort_month.end_of_month <= Date.current - 30
    end

    def matures_on
      cohort_month.end_of_month + 30
    end
  end
end
