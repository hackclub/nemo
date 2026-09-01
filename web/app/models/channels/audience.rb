module Channels
  class Audience
    KINDS = %w[private shared everyone].freeze
    DEFAULT = "private".freeze
    OPEN_TO_ALL = "everyone".freeze
    SHARED = %w[shared everyone].freeze

    JOIN = "LEFT JOIN app.channel_audience ca ON ca.channel_id = dim_channel.channel_id".freeze

    def self.everything
      Analytics::DimChannel.where(archived: false)
    end

    def self.open_to_all
      everything.joins(JOIN).where("ca.audience = ?", OPEN_TO_ALL)
    end

    def self.for(staff)
      return open_to_all if staff.nil?

      case Community::Access.role(staff, "read")
      when "curator" then everything
      when "analyst" then shared_or_granted(staff)
      else open_to_all
      end
    end

    def self.shared_or_granted(staff)
      everything.joins(JOIN).where(
        "ca.audience IN (?) OR dim_channel.channel_id IN (?)",
        SHARED, granted_ids(staff)
      )
    end

    def self.granted_ids(staff)
      return [nil] if staff.nil?

      ids = Grant.live.where(user_id: staff.user_id).pluck(:channel_id)
      ids.presence || [nil]
    end

    def self.may_see?(staff, channel)
      id = channel.respond_to?(:channel_id) ? channel.channel_id : channel.to_s
      self.for(staff).where(dim_channel: { channel_id: id }).exists?
    end

    def self.of(channel_id)
      Setting.where(channel_id: channel_id).pick(:audience) || DEFAULT
    end

    class Setting < ApplicationRecord
      self.table_name = "app.channel_audience"
      self.primary_key = "channel_id"
    end

    class Grant < ApplicationRecord
      self.table_name = "app.channel_grants"

      scope :live, -> { where(revoked_at: nil) }
    end
  end
end
