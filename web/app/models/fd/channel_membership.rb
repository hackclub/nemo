module Fd
  class ChannelMembership < ApplicationRecord
    self.table_name = "fd.channel_membership"
    self.primary_key = "channel_id"

    scope :seated, -> { where(inside: true) }

    def self.inside?(channel_id)
      return nil unless exists?

      seated.exists?(channel_id: channel_id)
    end

    def readonly?
      persisted?
    end
  end
end
