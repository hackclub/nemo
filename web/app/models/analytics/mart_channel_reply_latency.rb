module Analytics
  class MartChannelReplyLatency < ApplicationRecord
    self.table_name = "analytics.mart_channel_reply_latency"

    def readonly?
      true
    end
  end
end
