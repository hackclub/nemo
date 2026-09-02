class Current < ActiveSupport::CurrentAttributes
  attribute :moved, :flipped, :tuned, :fresh, :effective_capabilities, :held_roles

  def role_permissions
    self.moved ||= Fd::RolePermission.overrides
  end

  def forget_roles
    self.moved = nil
    self.effective_capabilities = nil
    self.held_roles = nil
  end

  def flags
    self.flipped ||= Fd::Flag.flipped
  end

  def forget_flags
    self.flipped = nil
  end

  def forget_tuned
    self.tuned = nil
  end

  def forget_fresh
    self.fresh = nil
  end
end
