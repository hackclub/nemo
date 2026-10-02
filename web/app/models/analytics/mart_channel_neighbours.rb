module Analytics
  class MartChannelNeighbours < ApplicationRecord
    self.table_name = "analytics.mart_channel_neighbours"

    def readonly?
      true
    end
  end
end
