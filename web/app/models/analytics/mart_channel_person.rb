module Analytics
  class MartChannelPerson < ApplicationRecord
    self.table_name = "analytics.mart_channel_person"

    def readonly?
      true
    end
  end
end
