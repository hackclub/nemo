module Analytics
  class MartResponseRate < ApplicationRecord
    self.table_name = "analytics.mart_response_rate"
    self.primary_key = "post_month"

    def readonly?
      true
    end

    def self.totals
      pick(
        Arel.sql("coalesce(sum(first_posts_checked), 0)"),
        Arel.sql("coalesce(sum(answered_by_member), 0)"),
        Arel.sql("coalesce(sum(bot_replied_first), 0)"),
        Arel.sql("coalesce(sum(bot_first_then_member), 0)")
      ).map(&:to_i)
    end
  end
end
