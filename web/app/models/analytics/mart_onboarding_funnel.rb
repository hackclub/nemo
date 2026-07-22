module Analytics
  class MartOnboardingFunnel < ApplicationRecord
    self.table_name = "analytics.mart_onboarding_funnel"

    def readonly?
      true
    end
  end
end
