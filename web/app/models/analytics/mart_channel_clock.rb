module Analytics
  class MartChannelClock < ApplicationRecord
    self.table_name = "analytics.mart_channel_clock"

    def readonly?
      true
    end
  end
end
