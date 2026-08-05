module Analytics
  class FctAnalyticsDay < ApplicationRecord
    self.table_name = "analytics.fct_analytics_day"
    self.primary_key = "source"

    def readonly?
      true
    end
  end
end
