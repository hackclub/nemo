module Fd
  class LoginEvent < ApplicationRecord
    self.table_name = "fd.login_event"

    AUDIT = "audit_logs".freeze
    ACCESS = "access_logs".freeze

    scope :recent_first, -> { order(last_at: :desc) }
    scope :with_agent, -> {
      joins("LEFT JOIN slack.user_agent agent ON agent.id = fd.login_event.ua_id")
        .select("fd.login_event.*, agent.ua, agent.app AS ua_app, agent.os AS ua_os")
    }
    scope :for_member, ->(user_id) { where(user_id: user_id) }
    scope :addressed, -> { where.not(ip_prefix: nil) }

    def readonly?
      persisted?
    end

    def device
      [ua_app, ua_os].compact_blank.join(" · ").presence
    end

    def location
      [country, region.presence && region.to_s].compact_blank.join(" · ").presence
    end
  end
end
