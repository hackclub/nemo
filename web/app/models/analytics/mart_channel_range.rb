module Analytics
  class MartChannelRange < ApplicationRecord
    self.table_name = "analytics.mart_channel_range"

    def readonly?
      true
    end
  end
end
