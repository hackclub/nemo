module Analytics
  class MartTeamStatsDaily < ApplicationRecord
    self.table_name = "analytics.mart_team_stats_daily"

    def readonly?
      true
    end
  end
end
