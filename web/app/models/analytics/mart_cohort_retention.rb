module Analytics
  class MartCohortRetention < ApplicationRecord
    self.table_name = "analytics.mart_cohort_retention"
    self.primary_key = "cohort_month"

    scope :measured, -> { where("measured_day_30 > 0 or measured_day_90 > 0") }

    def readonly?
      true
    end

    def day_30_coverage
      return nil if first_posters.to_i.zero?

      measured_day_30.to_f / first_posters
    end

    def day_90_coverage
      return nil if first_posters.to_i.zero?

      measured_day_90.to_f / first_posters
    end
  end
end
