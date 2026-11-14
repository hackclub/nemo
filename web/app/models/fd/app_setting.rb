module Fd
  class AppSetting < ApplicationRecord
    self.table_name = "fd.app_settings"
    self.primary_key = "key"

    JOIN_MODE = "nemo.join_mode".freeze
    FIREHOUSE = "nemo.firehouse_channel".freeze
    REPORTS = "nemo.reports_channel".freeze
    LOGS = "nemo.log_channel".freeze
    REACT_CHANNELS = "nemo.case_react_channels".freeze
    TRUSTED_SENDERS = "relay.trusted_senders".freeze
    LYLA_LINK = "lyla.link".freeze

    AUTORESPONSE_ON = "nemo.autoresponse_on".freeze
    AUTORESPONSE_EMOJI = "nemo.autoresponse_emoji".freeze
    AUTORESPONSE_CHANNEL = "nemo.autoresponse_channel".freeze
    AUTORESPONSE_BODY = "nemo.autoresponse_body".freeze
    AUTORESPONSE_COOLDOWN = "nemo.autoresponse_cooldown_days".freeze
    UNSUB_SHIELD_ON = "nemo.unsub_shield_on".freeze
    UNSUB_SHIELD_LINK = "nemo.unsub_shield_link".freeze

    SWEEP_SOON_HOURS = "nemo.sweep_soon_hours".freeze
    SWEEP_TELLS_MEMBER = "nemo.sweep_tells_member".freeze

    DEACTIVATE = "nemo.deactivate".freeze
    SESSION_RESET = "nemo.session_reset".freeze
    SESSION_RESET_STRIKES = "nemo.session_reset_strikes".freeze
    SESSION_RESET_MAX = "nemo.session_reset_max".freeze

    DEFAULT_SOON_HOURS = 36
    MAX_SOON_HOURS = 720

    DEFAULT_COOLDOWN_DAYS = 7

    DEFAULT_STRIKES = 2
    MAX_STRIKES = 100
    DEFAULT_RESET_MAX = 5
    MAX_RESETS = 1000

    ON = "on".freeze
    GUARDED = "guarded".freeze
    OFF = "off".freeze
    MODES = [ON, GUARDED, OFF].freeze
    DEFAULT_JOIN_MODE = GUARDED

    LOG = "log".freeze
    ACCOUNT_MODES = [OFF, LOG, ON].freeze

    def self.join_mode
      mode = find_by(key: JOIN_MODE)&.value.to_s.strip.downcase
      MODES.include?(mode) ? mode : DEFAULT_JOIN_MODE
    end

    def self.value(key)
      find_by(key: key)&.value.to_s.strip
    end

    def self.write(key, value, by:)
      setting = find_or_initialize_by(key: key)
      setting.update!(value: value, changed_by: by, changed_at: Time.current)
      setting
    end

    def self.firehouse_channel
      value(FIREHOUSE).presence
    end

    def self.set_firehouse_channel(channel_id, by:)
      write(FIREHOUSE, channel_id, by: by)
    end

    def self.reports_channel
      value(REPORTS).presence
    end

    def self.log_channel
      value(LOGS).presence
    end

    def self.case_react_channels
      value(REACT_CHANNELS).split(",").map(&:strip).reject(&:blank?)
    end

    def self.fd_channel_ids
      [firehouse_channel, reports_channel, log_channel, *case_react_channels].compact.uniq
    end

    def self.trusted_senders
      value(TRUSTED_SENDERS).split(",").map(&:strip).reject(&:blank?)
    end

    def self.set_trusted_senders(user_ids, by:)
      user_csv = Array(user_ids).map(&:to_s).map(&:strip).reject(&:blank?).uniq.join(",")
      return where(key: TRUSTED_SENDERS).destroy_all && nil if user_csv.blank?

      write(TRUSTED_SENDERS, user_csv, by: by)
    end

    def self.set_case_react_channels(ids, by:)
      channel_csv = Array(ids).map(&:to_s).map(&:strip).reject(&:blank?).uniq.join(",")
      return where(key: REACT_CHANNELS).destroy_all && nil if channel_csv.blank?

      write(REACT_CHANNELS, channel_csv, by: by)
    end

    def self.on?(key)
      value(key) == ON
    end

    def self.lyla_link?
      on?(LYLA_LINK)
    end

    def self.set_enabled(key, on, by:)
      write(key, on ? ON : OFF, by: by)
    end

    def self.words(key)
      value(key).split(",").map(&:strip).reject(&:blank?).uniq
    end

    def self.set_words(key, values, by:)
      normalized = Array(values).flat_map { |word| word.to_s.split(",") }
        .map { |word| word.strip.delete_prefix(":").delete_suffix(":") }
        .reject(&:blank?).uniq
      return where(key: key).destroy_all && nil if normalized.empty?

      write(key, normalized.join(","), by: by)
    end

    def self.autoresponse_emoji = words(AUTORESPONSE_EMOJI)

    def self.sweep_soon_hours
      hours = value(SWEEP_SOON_HOURS).to_i
      hours.positive? ? hours : DEFAULT_SOON_HOURS
    end

    def self.sweep_tells_member?
      value(SWEEP_TELLS_MEMBER) != OFF
    end

    def self.account_mode(key)
      mode = value(key).downcase
      ACCOUNT_MODES.include?(mode) ? mode : LOG
    end

    def self.deactivate_mode = account_mode(DEACTIVATE)

    def self.session_reset_mode = account_mode(SESSION_RESET)

    def self.number(key, default, minimum)
      number = Integer(value(key), 10, exception: false)
      number ? [number, minimum].max : default
    end

    def self.session_reset_strikes = number(SESSION_RESET_STRIKES, DEFAULT_STRIKES, 1)

    def self.session_reset_max = number(SESSION_RESET_MAX, DEFAULT_RESET_MAX, 0)

    def self.autoresponse_cooldown_days
      days = value(AUTORESPONSE_COOLDOWN).to_i
      days.positive? ? days : DEFAULT_COOLDOWN_DAYS
    end

    def self.set_join_mode(mode, by:)
      raise ArgumentError, "#{mode} is not a join mode" unless MODES.include?(mode)

      setting = find_or_initialize_by(key: JOIN_MODE)
      setting.update!(value: mode, changed_by: by, changed_at: Time.current)
      setting
    end
  end
end
