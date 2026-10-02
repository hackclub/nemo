module Analytics
  class MartChannelConcentration < ApplicationRecord
    self.table_name = "analytics.mart_channel_concentration"

    def readonly?
      true
    end
  end
end
