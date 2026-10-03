module Fd
  class ChannelGuard < ApplicationRecord
    self.table_name = "fd.channel_guards"

    BOT_ALLOWLIST = "bot_allowlist".freeze
    READONLY = "readonly".freeze
    SLOWMODE = "slowmode".freeze
    ACCOUNT_AGE = "account_age".freeze
    KINDS = [BOT_ALLOWLIST, READONLY, SLOWMODE, ACCOUNT_AGE].freeze

    ALLOWS = [BOT_ALLOWLIST, READONLY, SLOWMODE].freeze

    SLOWEST = 3600
    OLDEST = 365

    SECONDS_TO_START = 30
    DAYS_TO_START = 7

    has_many :allows, class_name: "Fd::ChannelGuardAllow", foreign_key: :guard_id,
      inverse_of: :guard, dependent: :destroy
    has_many :events, class_name: "Fd::ChannelGuardEvent", foreign_key: :guard_id,
      inverse_of: :guard, dependent: :destroy
    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, optional: true,
      inverse_of: false

    scope :live, -> { where(state: "live") }
    scope :allowlists, -> { where(kind: BOT_ALLOWLIST) }
    scope :of_kind, ->(kind) { where(kind: kind) }

    def self.live_for(channel_id, kind: BOT_ALLOWLIST)
      live.where(kind: kind).find_by(channel_id: channel_id)
    end

    def self.live_by_kind(channel_id)
      live.where(channel_id: channel_id).index_by(&:kind)
    end

    def self.kind?(kind) = KINDS.include?(kind)

    def live? = state == "live"

    def takes_allows? = ALLOWS.include?(kind)

    def seconds = settings["seconds"].to_i

    def threads? = settings["threads"] == true

    def min_age_days = settings["min_age_days"].to_i

    def people_named
      [opened_by, lifted_by].compact + allows.map(&:added_by)
    end
  end
end
