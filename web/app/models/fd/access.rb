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

      staff.community_manager? || bootstrap?(staff.user_id)
    end

    def self.role(staff)
      return nil if staff.nil?

      AccessGrant.role_for(staff.user_id)
    end

    def self.allow?(staff, key, record = nil)
      return false if staff.nil?
      return within_scope?(staff, Permission.scope(key), record) if manager?(staff)

      held = staff.role
      return false if held.nil?
      return false unless Permission.roles(key).include?(held)

      within_scope?(staff, Permission.scope(key), record)
    end

    def self.why_not(staff, key, record = nil)
      held = manager?(staff) ? MANAGER_ROLE : staff&.role
      return "you hold no access" if held.nil?
      return Permission.refusal(key) unless Permission.roles(key).include?(held)
      return nil if within_scope?(staff, Permission.scope(key), record)
      return not_yours(record) if record.respond_to?(:mine_or_free?)

      "that is not yours"
    end

    def self.not_yours(kase)
      "case #{kase.id} is assigned to #{kase.assignee_handles}, not to you"
    end

    def self.within_scope?(staff, scope, record)
      return true if scope.nil? || record.nil?

      case scope
      when :assigned then record.respond_to?(:mine_or_free?) && record.mine_or_free?(staff.user_id)
      when :author then record.respond_to?(:author) && record.author == staff.user_id
      else true
      end
    end
  end
end
