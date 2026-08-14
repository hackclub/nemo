module Fd
  class Access
    def self.role(staff)
      return nil if staff.nil?

      staff.community_manager? ? "community_manager" : "firefighter"
    end

    def self.allow?(staff, key, record = nil)
      held = staff&.role
      return false if held.nil?
      return false unless Permission.roles(key).include?(held)

      within_scope?(staff, Permission.scope(key), record)
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
