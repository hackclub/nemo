module Analytics
  class MartParticipationConcentration < ApplicationRecord
    self.table_name = "analytics.mart_participation_concentration"
    self.primary_key = "poster_pct"

    scope :curve, -> { order(:poster_pct) }

    def readonly?
      true
    end
  end
end
