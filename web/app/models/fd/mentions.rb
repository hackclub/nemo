module Fd
  module Mentions
    SLACK = /<@([UW][A-Z0-9]{2,})>/
    TYPED = /(?<![\w<@])@?([UW](?=[A-Z0-9]*\d)[A-Z0-9]{6,})\b(?!@)/

    def self.normalise(text)
      return text if text.blank?

      text.gsub(TYPED) { "<@#{Regexp.last_match(1)}>" }
    end

    def self.ids(text)
      return [] if text.blank?

      text.scan(SLACK).flatten.uniq
    end

    def self.split(text)
      text.to_s.split(/(<@[UW][A-Z0-9]{2,}>)/)
    end
  end
end
