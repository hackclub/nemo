module Fd
  class ChannelGuardEvent < ApplicationRecord
    self.table_name = "fd.channel_guard_events"

    KICKED = "kicked".freeze
    DELETED = "deleted".freeze
    LET_PAST = "let_past".freeze

    belongs_to :guard, class_name: "Fd::ChannelGuard", foreign_key: :guard_id,
      inverse_of: :events

    scope :newest_first, -> { order(at: :desc) }
    scope :for_kind, ->(channel_id, kind) {
      where(channel_id: channel_id,
        guard_id: ChannelGuard.where(channel_id: channel_id, kind: kind).select(:id))
    }
    scope :turned_away, -> { where(verb: [KICKED, DELETED]) }

    def readonly?
      persisted?
    end
  end
end
