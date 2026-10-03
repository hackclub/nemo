module Fd
  class LoginEvent < ApplicationRecord
    self.table_name = "fd.login_event"

    AUDIT = "audit_logs".freeze
    ACCESS = "access_logs".freeze

    scope :recent_first, -> { order(at: :desc) }
    scope :for_member, ->(user_id) { where(user_id: user_id) }
    scope :addressed, -> { where.not(ip_prefix: nil) }

    def readonly?
      persisted?
    end

    def failed? = action == "user_login_failed"

    def anomaly? = action == "anomaly"

    def device
      [ua_app, ua_os].compact_blank.join(" · ").presence
    end

    def location
      [country, region.presence && region.to_s].compact_blank.join(" · ").presence
    end
  end
end
