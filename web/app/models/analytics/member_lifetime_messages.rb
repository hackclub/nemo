module Analytics
  class MemberLifetimeMessages < ApplicationRecord
    self.table_name = "analytics.fct_member_lifetime_messages"
    self.primary_key = "user_id"

    def readonly?
      true
    end
  end
end
