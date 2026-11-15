module Fd
  module Duration
    PATTERN = /\A(\d{1,6})([mhdw])\z/i
    UNITS = { "m" => 1.minute, "h" => 1.hour, "d" => 1.day, "w" => 1.week }.freeze
    MIN = 1.minute
    MAX = 365.days
    INVALID = "Enter a duration such as 30m, 12h, 7d or 2w".freeze

    def self.read(text)
      text = text.to_s.strip
      return [nil, nil] if text.blank?

      match = PATTERN.match(text)
      length = match && (match[1].to_i * UNITS.fetch(match[2].downcase))
      return [nil, INVALID] if length.nil? || length < MIN || length > MAX

      [length, nil]
    end
  end
end
