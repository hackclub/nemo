module Analytics
  class MartMemberStreak < ApplicationRecord
    self.table_name = "analytics.mart_member_streak"

    scope :mine, ->(user_id) { where(user_id: user_id) }
    scope :counting, ->(basis) { where(basis: basis) }

    def running?
      current_days.to_i.positive?
    end

    def readonly?
      true
    end
  end
end
