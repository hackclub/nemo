module Analytics
  class MemberChannel < ApplicationRecord
    self.table_name = "analytics.fct_member_channel"

    scope :mine, ->(user_id) { where(user_id: user_id) }

    def readonly?
      true
    end
  end
end
