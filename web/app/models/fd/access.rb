module Fd
  class Access
    BOOTSTRAP = "BOOTSTRAP_ADMIN_SLACK_ID".freeze
    MANAGER_ROLE = "community_manager".freeze
    MANAGER_LABEL = "Community manager".freeze

    def self.bootstrap_ids
      ENV[BOOTSTRAP].to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def self.bootstrap?(user_id)
      user_id.present? && bootstrap_ids.include?(user_id)
    end

    def self.manager?(staff)
      return false if staff.nil?
      return true if bootstrap?(staff.user_id)

      Authz.everything?(staff)
    end

    def self.allow?(staff, key, record = nil)
      Authz.may?(staff, key, record)
    end

    def self.why_not(staff, key, record = nil)
      return nil if allow?(staff, key, record)
      return "you hold no access" if staff.nil? || Authz.roles_held(staff.user_id).empty?
      return Authz.refusal(key) unless Authz.holds?(staff, key)

      "that is not yours"
    end
  end
end
