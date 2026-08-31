module Api
  class ChannelSweep < ApplicationRecord
    self.table_name = "api.channel_sweep"
    self.primary_key = "channel_id"

    def self.stamp!(channel_id, managers)
      upsert({ channel_id: channel_id, synced_at: Time.current, managers: managers },
        unique_by: :channel_id)
    end

    def stale?(ttl)
      synced_at < ttl.ago
    end
  end
end
