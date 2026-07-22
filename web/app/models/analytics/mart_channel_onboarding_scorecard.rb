module Analytics
  class MartChannelOnboardingScorecard < ApplicationRecord
    self.table_name = "analytics.mart_channel_onboarding_scorecard"

    def readonly?
      true
    end
  end
end
