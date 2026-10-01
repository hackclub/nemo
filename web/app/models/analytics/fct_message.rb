module Analytics
  class FctMessage < ApplicationRecord
    self.table_name = "analytics.fct_message"
    self.primary_key = [:channel_id, :ts]

    def readonly?
      true
    end

    def author = author_id

    def self.post(channel_id, ts)
      where(channel_id: channel_id, ts: ts).first
    end
  end
end
