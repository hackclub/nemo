module Analytics
  class MartArchiveDayCoverage < ApplicationRecord
    self.table_name = "analytics.mart_archive_day_coverage"
    self.primary_key = "ds"

    scope :newest_first, -> { order(ds: :desc) }

    def readonly?
      true
    end
  end
end
