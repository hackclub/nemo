module Fd
  class ChannelJoin < ApplicationRecord
    self.table_name = "fd.channel_joins"

    IN = %w[joined rejoined].freeze

    scope :newest_first, -> { order(at: :desc) }

    def self.latest_for(channel_id)
      newest_first.find_by(channel_id: channel_id)
    end

    def inside? = IN.include?(verb)

    def refused? = verb == "refused"

    def readonly?
      persisted?
    end
  end
end
