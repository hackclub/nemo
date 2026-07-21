module Analytics
  class MartParticipation < ApplicationRecord
    self.table_name = "analytics.mart_participation"

    def readonly?
      true
    end
  end
end
