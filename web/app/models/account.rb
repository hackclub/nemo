class Account < ApplicationRecord
  self.table_name = "account"
  self.primary_key = "user_id"

  def manager?
    Fd::Access.manager?(self)
  end

  def may?(key, record = nil)
    Fd::Access.allow?(self, key, record)
  end
end
