module Analytics
  class FctThread < ApplicationRecord
    self.table_name = "analytics.fct_thread"
    self.primary_key = [:channel_id, :root_ts]

    def readonly?
      true
    end
  end
end
