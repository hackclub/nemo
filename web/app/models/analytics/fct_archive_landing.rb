module Analytics
  class FctArchiveLanding < ApplicationRecord
    self.table_name = "analytics.fct_archive_landing"
    self.primary_key = nil

    def readonly?
      true
    end
  end
end
