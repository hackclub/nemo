module Fd
  class AppSetting < ApplicationRecord
    self.table_name = "fd.app_settings"
    self.primary_key = "key"

    JOIN_MODE = "nemo.join_mode".freeze
    FIREHOUSE = "nemo.firehouse_channel".freeze
    REACT_CHANNELS = "nemo.case_react_channels".freeze

    ON = "on".freeze
    GUARDED = "guarded".freeze
    OFF = "off".freeze
    MODES = [ON, GUARDED, OFF].freeze
    FALL_BACK = GUARDED

    def self.join_mode
      said = find_by(key: JOIN_MODE)&.value.to_s.strip.downcase
      MODES.include?(said) ? said : FALL_BACK
    end

    def self.said(key)
      find_by(key: key)&.value.to_s.strip
    end

    def self.keep(key, value, by:)
      one = find_or_initialize_by(key: key)
      one.update!(value: value, changed_by: by, changed_at: Time.current)
      one
    end

    def self.firehouse_channel
      said(FIREHOUSE).presence
    end

    def self.set_firehouse_channel(channel_id, by:)
      keep(FIREHOUSE, channel_id, by: by)
    end

    def self.case_react_channels
      said(REACT_CHANNELS).split(",").map(&:strip).reject(&:blank?)
    end

    def self.set_case_react_channels(ids, by:)
      said = Array(ids).map(&:to_s).map(&:strip).reject(&:blank?).uniq.join(",")
      return where(key: REACT_CHANNELS).destroy_all && nil if said.blank?

      keep(REACT_CHANNELS, said, by: by)
    end

    def self.set_join_mode(how, by:)
      raise ArgumentError, "#{how} is not a join mode" unless MODES.include?(how)

      one = find_or_initialize_by(key: JOIN_MODE)
      one.update!(value: how, changed_by: by, changed_at: Time.current)
      one
    end
  end
end
