class Staff < ApplicationRecord
  self.table_name = "staff"
  self.primary_key = "user_id"

  after_create :grant_the_first_role

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

  private

  def grant_the_first_role
    return unless community_manager?
    return if Fd::AccessGrant.role_for(user_id)

    Fd::AccessGrant.give!(user_id, role: "community_manager", by: user_id,
      reason: "seeded as a community manager")
  end
end
