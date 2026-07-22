module Analytics
  class MartOnboardingRecurrenceFunnel < ApplicationRecord
    self.table_name = "analytics.mart_onboarding_recurrence_funnel"

    def readonly?
      true
    end
  end
end
