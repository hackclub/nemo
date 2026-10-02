module Analytics
  class FctQualityResult < ApplicationRecord
    self.table_name = "analytics.fct_quality_result"
    self.primary_key = "quality_result_id"

    scope :failing, -> { where(status: "fail") }
    scope :recent_first, -> { order(checked_at: :desc) }

    def readonly?
      true
    end
  end
end
