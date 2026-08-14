module Fd
  class RolePermission < ApplicationRecord
    self.table_name = "fd.role_permissions"

    class NotAllowed < StandardError; end

    def self.overrides
      pluck(:role, :permission_key, :allowed)
        .each_with_object({}) { |(role, key, allowed), map| map[[role, key]] = allowed }
    end

    def self.set!(role, key, allowed, by:)
      role = role.to_s
      key = key.to_s
      check(role, key, allowed)

      row = find_or_initialize_by(role: role, permission_key: key)
      row.update!(allowed: allowed, changed_by: by, changed_at: Time.current)
      Current.forget_roles
      row
    end

    def self.check(role, key, allowed)
      refuse "#{role} is not a role" unless Permission::ROLES.include?(role)
      refuse "#{key} is not a permission" unless Permission.keys.include?(key)
      refuse "#{key} cannot be moved" if Permission.locked?(key)
      return if allowed
      return unless (Permission.roles(key) - [role]).empty?

      refuse "#{key} would then be held by nobody"
    end

    def self.moved?(key)
      Permission.roles(key) != Permission.default_roles(key)
    end

    def self.refuse(why)
      raise NotAllowed, why
    end

    def default? = Permission.default_roles(permission_key).include?(role) == allowed
  end
end
