module Analytics
  class MartActivation < ApplicationRecord
    self.table_name = "analytics.mart_activation"

    def readonly?
      true
    end
  end
end
