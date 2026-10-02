module Analytics
  class MartChannelDay < ApplicationRecord
    self.table_name = "analytics.mart_channel_day"

    def readonly?
      true
    end
  end
end
