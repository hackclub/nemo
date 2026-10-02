module Analytics
  class MartMemberDay < ApplicationRecord
    self.table_name = "analytics.mart_member_day"

    scope :mine, ->(user_id) { where(user_id: user_id) }
    scope :between, ->(from, to) { where(ds: from..to) }

    def readonly?
      true
    end
  end
end
