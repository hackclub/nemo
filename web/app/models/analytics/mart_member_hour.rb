module Analytics
  class MartMemberHour < ApplicationRecord
    self.table_name = "analytics.mart_member_hour"

    def readonly?
      true
    end
  end
end
