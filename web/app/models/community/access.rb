module Community
  class Access
    SUPERADMIN_FD_ROLE = "community_manager".freeze

    def self.superadmin?(staff)
      staff.present? && Fd::Access.role(staff) == SUPERADMIN_FD_ROLE
    end

    def self.role(staff, family)
      return nil if staff.nil?
      return Permission.superadmin(family) if superadmin?(staff)

      Grant.role_for(staff.user_id, family)
    end

    def self.held(staff)
      return {} if staff.nil?

      Permission.families.index_with { |family| role(staff, family) }.compact
    end

    def self.anything?(staff)
      held(staff).any?
    end

    def self.allow?(staff, key, record = nil)
      held = role(staff, Permission.family(key))
      return false unless Permission.holds?(held, key)

      within_scope?(staff, key, record)
    end

    def self.why_not(staff, key, record = nil)
      return "you hold no community access" if role(staff, Permission.family(key)).nil?
      return Permission.refusal(key) unless allow?(staff, key, record)

      nil
    end

    def self.within_scope?(staff, key, record)
      return true unless key.to_s == "analytics.channel.read"
      return true if record.nil?

      Channels::Audience.may_see?(staff, record)
    end
  end
end
