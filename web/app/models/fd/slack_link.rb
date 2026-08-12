module Fd
  class SlackLink
    HOST = "hackclub.slack.com".freeze
    ARCHIVES = "https://#{HOST}/archives".freeze

    CHANNEL = /\A[CDG][A-Z0-9]{2,}\z/
    PATH_STAMP = /\Ap(\d{7,20})\z/
    THREAD_TS = /\A\d{1,12}\.\d{6}\z/

    Ref = Struct.new(:channel_id, :thread_ts, keyword_init: true)

    def self.parse(raw)
      url = URI.parse(raw.to_s.strip)
      return nil unless url.is_a?(URI::HTTP)
      return nil unless url.host&.downcase == HOST

      parts = url.path.split("/").reject(&:empty?)
      return nil unless parts.size == 3 && parts.first == "archives"

      channel_id = parts[1]
      return nil unless channel_id.match?(CHANNEL)

      thread_ts = root_ts(url.query, parts[2])
      return nil if thread_ts.nil?

      Ref.new(channel_id: channel_id, thread_ts: thread_ts)
    rescue URI::InvalidURIError
      nil
    end

    def self.root_ts(query, stamp)
      from_query = query_value(query, "thread_ts")
      return from_query if from_query&.match?(THREAD_TS)

      match = PATH_STAMP.match(stamp.to_s)
      return nil if match.nil?

      digits = match[1]
      "#{digits[0..-7]}.#{digits[-6..]}"
    end

    def self.query_value(query, key)
      return nil if query.blank?

      URI.decode_www_form(query).to_h[key]
    rescue ArgumentError
      nil
    end

    def self.url_for(channel_id, thread_ts)
      "#{ARCHIVES}/#{channel_id}/p#{thread_ts.to_s.delete('.')}"
    end
  end
end
