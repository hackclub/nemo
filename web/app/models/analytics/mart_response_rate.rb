module Analytics
  class MartResponseRate < ApplicationRecord
    self.table_name = "analytics.mart_response_rate"
    self.primary_key = "post_month"

    def readonly?
      true
    end
  end
end
