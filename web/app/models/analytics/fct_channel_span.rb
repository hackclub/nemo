module Analytics
  class FctChannelSpan < ApplicationRecord
    self.table_name = "analytics.fct_channel_span"
    self.primary_key = "channel_id"

    def readonly?
      true
    end
  end
end
