module Fd
  module EndTime
    TIME = /\A([01]\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\z/
    END_OR_DURATION = "Use End or Duration, not both".freeze

    def self.read(date_text, time_text)
      date_text = date_text.to_s.strip
      time_text = time_text.to_s.strip
      return [nil, time_text.present? ? "Enter a date for the end time" : nil] if date_text.blank?

      on = Date.strptime(date_text, "%Y-%m-%d")
      return [on.end_of_day, nil] if time_text.blank?

      match = TIME.match(time_text)
      return [nil, "#{time_text} is not a time"] if match.nil?

      [Time.zone.local(on.year, on.month, on.day, match[1].to_i, match[2].to_i), nil]
    rescue Date::Error
      [nil, "#{date_text} is not a date"]
    end

    def self.read_with_duration(date_text, time_text, duration_text, from:)
      length, error = Duration.read(duration_text)
      return [nil, error] if error
      return read(date_text, time_text) if length.nil?
      return [nil, END_OR_DURATION] if date_text.to_s.strip.present? || time_text.to_s.strip.present?

      [(from + length).change(sec: 0), nil]
    end

    def self.future(date_text, time_text, required: false, now: Time.current)
      ends, error = read(date_text, time_text)
      return [nil, error] if error
      return [nil, required ? "Enter the end date" : nil] if ends.nil?
      return [nil, "End must be in the future"] if ends <= now

      [ends, nil]
    end
  end
end
