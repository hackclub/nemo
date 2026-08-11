module Analytics
  class MemberWindow < ApplicationRecord
    self.table_name = "analytics.fct_member_window"

    LIFETIME_SOURCE = "admin_analytics_member_range"

    scope :lifetime, -> { where(source: LIFETIME_SOURCE) }

    def readonly?
      true
    end
  end
end
