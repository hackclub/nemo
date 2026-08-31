module Api
  class Setting < ApplicationRecord
    self.table_name = "api.setting"
    self.primary_key = "key"

    DEFAULTS = {
      "rate_per_minute" => 20,
      "tokens_per_owner" => 3
    }.freeze

    def self.value(key)
      DEFAULTS.fetch(key.to_s)
      find_by(key: key.to_s)&.value || DEFAULTS.fetch(key.to_s)
    end

    def self.set!(key, value, by:)
      DEFAULTS.fetch(key.to_s)
      row = find_or_initialize_by(key: key.to_s)
      row.update!(value: value, changed_by: by, changed_at: Time.current)
      row
    end
  end
end
