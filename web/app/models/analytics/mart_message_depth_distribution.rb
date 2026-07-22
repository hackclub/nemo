module Analytics
  class MartMessageDepthDistribution < ApplicationRecord
    self.table_name = "analytics.mart_message_depth_distribution"

    def readonly?
      true
    end
  end
end
