module Channels
  class Audience
    KINDS = %w[granted public].freeze
    DEFAULT = "granted".freeze
    OPEN_TO_ALL = "public".freeze
    OPEN = %w[public everyone].freeze
    WAS = { "everyone" => "public", "shared" => "granted", "private" => "granted" }.freeze

    def self.settled(audience)
      WAS.fetch(audience.to_s, audience.to_s)
    end

    JOIN = "LEFT JOIN app.channel_audience ca ON ca.channel_id = dim_channel.channel_id".freeze

    def self.everything
      Analytics::DimChannel.where(archived: false)
    end

    def self.open_to_all
      everything.joins(JOIN).where("ca.audience IN (?)", OPEN)
    end

    VISIBLE = "app.may_see_channel(?, dim_channel.channel_id)".freeze

    def self.for(staff)
      return open_to_all if staff.nil?
      return everything if Fd::Access.manager?(staff)

      everything.where(ApplicationRecord.sanitize_sql([VISIBLE, staff.user_id]))
    end

    def self.granted_ids(staff)
      return [nil] if staff.nil?

      ids = Grant.live.where(user_id: staff.user_id).pluck(:channel_id)
      ids.presence || [nil]
    end

    def self.may_see?(staff, channel)
      id = channel.respond_to?(:channel_id) ? channel.channel_id : channel.to_s
      return false if staff.nil? || id.blank?

      ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql(["SELECT app.may_see_channel(?, ?)", staff.user_id, id])
      )
    end

    def self.of(channel_id)
      settled(Setting.where(channel_id: channel_id).pick(:audience) || DEFAULT)
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
