module Fd
  class ChannelGuard < ApplicationRecord
    self.table_name = "fd.channel_guards"

    BOT_ALLOWLIST = "bot_allowlist".freeze
    KINDS = [BOT_ALLOWLIST].freeze

    has_many :allows, class_name: "Fd::ChannelGuardAllow", foreign_key: :guard_id,
      inverse_of: :guard, dependent: :destroy
    has_many :events, class_name: "Fd::ChannelGuardEvent", foreign_key: :guard_id,
      inverse_of: :guard, dependent: :destroy
    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, optional: true,
      inverse_of: false

    scope :live, -> { where(state: "live") }
    scope :allowlists, -> { where(kind: BOT_ALLOWLIST) }

    def self.live_for(channel_id, kind: BOT_ALLOWLIST)
      live.where(kind: kind).find_by(channel_id: channel_id)
    end

    def live? = state == "live"

    def people_named
      [opened_by, lifted_by].compact + allows.map(&:added_by)
    end
  end
end
