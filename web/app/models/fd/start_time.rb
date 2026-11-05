module Fd
  module StartTime
    def self.read(date_text, time_text, now: Time.current)
      date_text = date_text.to_s.strip
      time_text = time_text.to_s.strip
      return [nil, time_text.present? ? "Enter a date for the start time" : nil] if date_text.blank?

      on = Date.strptime(date_text, "%Y-%m-%d")
      match = EndTime::TIME.match(time_text)
      return [nil, "#{time_text} is not a time"] if time_text.present? && match.nil?

      starts = Time.utc(on.year, on.month, on.day, match ? match[1].to_i : 0, match ? match[2].to_i : 0)
      return [nil, "Start must be in the future"] if starts <= now

      [starts, nil]
    rescue Date::Error
      [nil, "#{date_text} is not a date"]
    end

    def self.error(starts_at, expires_at)
      return nil if starts_at.nil? || expires_at.nil? || expires_at > starts_at

      "End must be after the start"
    end
  end
end
