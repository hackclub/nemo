module Fd
  class ChannelGuardAllow < ApplicationRecord
    self.table_name = "fd.channel_guard_allows"
    self.primary_key = [:guard_id, :subject_id]

    belongs_to :guard, class_name: "Fd::ChannelGuard", foreign_key: :guard_id,
      inverse_of: :allows

    scope :oldest_first, -> { order(:added_at) }

    def name
      label.presence || subject_id
    end
  end
end
