module Analytics
  class MartGrowth < ApplicationRecord
    self.table_name = "analytics.mart_growth"

    def readonly?
      true
    end
  end
end
