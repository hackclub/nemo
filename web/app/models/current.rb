class Current < ActiveSupport::CurrentAttributes
  attribute :moved

  def role_permissions
    self.moved ||= Fd::RolePermission.overrides
  end

  def forget_roles
    self.moved = nil
  end
end
