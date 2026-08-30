module Api
  class RequestLog < ApplicationRecord
    self.table_name = "api.request_log"

    MANAGER = "manager".freeze
    NOT_MANAGER = "not_manager".freeze
    WITHHELD = "withheld".freeze

    def self.log!(token_id, channel_id, outcomes)
      return if outcomes.empty?

      now = Time.current
      insert_all(outcomes.map do |user_id, outcome|
        { token_id: token_id, channel_id: channel_id, subject_user_id: user_id,
          outcome: outcome, at: now }
      end)
    end
  end
end
