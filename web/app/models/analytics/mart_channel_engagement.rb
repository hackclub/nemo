module Analytics
  class MartChannelEngagement < ApplicationRecord
    self.table_name = "analytics.mart_channel_engagement"
    self.primary_key = "channel_id"

    def readonly?
      true
    end
  end
end
