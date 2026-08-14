class Staff < ApplicationRecord
  self.table_name = "staff"
  self.primary_key = "user_id"

  def role
    return @role if defined?(@role)

    @role = Fd::Access.role(self)
  end

  def lead?
    Fd::Permission::LEAD.include?(role)
  end

  def manager?
    role == "community_manager"
  end

  def may?(key, record = nil)
    Fd::Access.allow?(self, key, record)
  end
end
