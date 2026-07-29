module Analytics
  class MartTeamStats < ApplicationRecord
    self.table_name = "analytics.mart_team_stats"

    def readonly?
      true
    end
  end
end
