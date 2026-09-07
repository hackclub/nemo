module Analytics
  class MartActivityClock < ApplicationRecord
    self.table_name = "analytics.mart_activity_clock"

    def readonly?
      true
    end
  end
end
