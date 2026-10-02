module Analytics
  class MartChannelNewcomers < ApplicationRecord
    self.table_name = "analytics.mart_channel_newcomers"

    def readonly?
      true
    end
  end
end
