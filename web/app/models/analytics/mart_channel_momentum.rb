module Analytics
  class MartChannelMomentum < ApplicationRecord
    self.table_name = "analytics.mart_channel_momentum"
    self.primary_key = "channel_id"

    TILES = 22

    scope :ranked, -> { order(:rank) }

    def readonly?
      true
    end

    def self.top(limit: TILES, channel_ids: nil)
      scope = ranked
      scope = scope.where(channel_id: channel_ids) if channel_ids
      scope.limit(limit).to_a
    end

    def grew?
      pct_change.present? && pct_change.to_f.positive?
    end
  end
end
