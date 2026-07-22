module Analytics
  class DimChannel < ApplicationRecord
    self.table_name = "analytics.dim_channel"
    self.primary_key = "channel_id"

    def readonly?
      true
    end
  end
end
