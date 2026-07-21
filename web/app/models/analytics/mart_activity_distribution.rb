module Analytics
  class MartActivityDistribution < ApplicationRecord
    self.table_name = "analytics.mart_activity_distribution"

    def readonly?
      true
    end
  end
end
