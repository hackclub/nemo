module Analytics
  class DimMemberCohort < ApplicationRecord
    self.table_name = "analytics.dim_member_cohort"
    self.primary_key = "user_id"

    def readonly?
      true
    end
  end
end
