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
