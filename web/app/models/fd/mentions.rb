module Fd
  module Mentions
    SLACK = /<@([UW][A-Z0-9]{2,})(?:\|[^>]*)?>/
    CHANNEL = /<#(C[A-Z0-9]{2,})(?:\|([^>]*))?>/
    TYPED = /(?<![\w<@])@?([UW](?=[A-Z0-9]*\d)[A-Z0-9]{6,})\b(?!@)/
    ANY = /(<@[UW][A-Z0-9]{2,}(?:\|[^>]*)?>|<\#C[A-Z0-9]{2,}(?:\|[^>]*)?>)/

    def self.normalise(text)
      return text if text.blank?

      text.gsub(TYPED) { "<@#{Regexp.last_match(1)}>" }
    end

    def self.ids(text)
      return [] if text.blank?

      text.scan(SLACK).flatten.uniq
    end

    def self.channel_ids(text)
      return [] if text.blank?

      text.scan(CHANNEL).map(&:first).uniq
    end

    def self.split(text)
      text.to_s.split(ANY)
    end
  end
end
