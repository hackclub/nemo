module Analytics
  class MartTeamStatsMonthly < ApplicationRecord
    self.table_name = "analytics.mart_team_stats_monthly"

    def readonly?
      true
    end
  end
end
