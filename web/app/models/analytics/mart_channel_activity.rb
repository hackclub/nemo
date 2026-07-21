module Analytics
  class MartChannelActivity < ApplicationRecord
    self.table_name = "analytics.mart_channel_activity"

    def readonly?
      true
    end
  end
end
