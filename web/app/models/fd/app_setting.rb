module Fd
  class AppSetting < ApplicationRecord
    self.table_name = "fd.app_settings"
    self.primary_key = "key"

    JOIN_MODE = "nemo.join_mode".freeze

    ON = "on".freeze
    GUARDED = "guarded".freeze
    OFF = "off".freeze
    MODES = [ON, GUARDED, OFF].freeze
    FALL_BACK = GUARDED

    def self.join_mode
      said = find_by(key: JOIN_MODE)&.value.to_s.strip.downcase
      MODES.include?(said) ? said : FALL_BACK
    end

    def self.set_join_mode(how, by:)
      raise ArgumentError, "#{how} is not a join mode" unless MODES.include?(how)

      one = find_or_initialize_by(key: JOIN_MODE)
      one.update!(value: how, changed_by: by, changed_at: Time.current)
      one
    end
  end
end
