module Api
  class ChannelManager < ApplicationRecord
    self.table_name = "api.channel_manager"
    self.primary_key = [:channel_id, :user_id]

    def self.user_ids_in(channel_id)
      where(channel_id: channel_id).order(:user_id).pluck(:user_id)
    end
  end
end
