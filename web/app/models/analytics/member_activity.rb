module Analytics
  class MemberActivity < ApplicationRecord
    self.table_name = "analytics.fct_member_activity"

    scope :mine, ->(user_id) { where(user_id: user_id) }
    scope :between, ->(from, to) { where(window_start: from..to) }
    scope :present, -> { where("coalesce(days_active, 0) > 0") }

    def readonly?
      true
    end
  end
end
