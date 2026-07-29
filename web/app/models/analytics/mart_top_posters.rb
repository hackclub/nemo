module Analytics
  class MartTopPosters < ApplicationRecord
    self.table_name = "analytics.mart_top_posters"

    def readonly?
      true
    end
  end
end
