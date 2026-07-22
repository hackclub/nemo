module Analytics
  class MartFastReplyVsRetention < ApplicationRecord
    self.table_name = "analytics.mart_fast_reply_vs_retention"

    def readonly?
      true
    end
  end
end
