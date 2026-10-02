module Analytics
  class FctChannelWalk < ApplicationRecord
    self.table_name = "analytics.fct_channel_walk"
    self.primary_key = "channel_id"

    scope :failed, -> { where.not(last_error: nil) }

    def readonly?
      true
    end
  end
end
