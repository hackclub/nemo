module Analytics
  class MartAccountType < ApplicationRecord
    self.table_name = "analytics.mart_account_type"

    def readonly?
      true
    end
  end
end
