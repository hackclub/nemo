module Api
  class Event < ApplicationRecord
    self.table_name = "api.event_log"

    def self.record!(verb, actor:, subject: nil, detail: nil)
      create!(verb: verb, actor_user_id: actor, subject: subject, detail: detail)
    end
  end
end
