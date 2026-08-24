class Current < ActiveSupport::CurrentAttributes
  attribute :moved, :flipped

  def role_permissions
    self.moved ||= Fd::RolePermission.overrides
  end

  def forget_roles
    self.moved = nil
  end

  def flags
    self.flipped ||= Fd::Flag.flipped
  end

  def forget_flags
    self.flipped = nil
  end
end
