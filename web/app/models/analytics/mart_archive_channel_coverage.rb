module Analytics
  class MartArchiveChannelCoverage < ApplicationRecord
    self.table_name = "analytics.mart_archive_channel_coverage"
    self.primary_key = "channel_id"

    scope :reachable, -> { where(unreachable_reason: nil) }
    scope :held, -> { where("messages_held > 0") }

    def readonly?
      true
    end
  end
end
