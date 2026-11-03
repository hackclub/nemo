require "net/http"

module Slack
  class Emoji
    URL = "https://badger.hackclub.dev/api/emoji".freeze
    TTL = 12.hours
    MISSING_TTL = 1.hour
    LOCAL_TTL = 10.minutes
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    ALIAS = "alias:".freeze
    HOPS = 3

    def self.for(names)
      requested = Array(names).map(&:to_s).reject(&:empty?).uniq
      return {} if requested.empty?

      cached = Rails.cache.read_multi(*requested.map { |name| key_for(name) })
      emoji = requested.index_with { |name| cached[key_for(name)] }
      missing = requested.reject { |name| cached.key?(key_for(name)) }
      emoji = emoji.merge(looked_up(missing)) if missing.any?
      emoji.compact
    end

    def self.key_for(name) = "slack/emoji/#{name}"

    def self.looked_up(missing)
      map = all
      return missing.index_with { nil } if map.nil?

      urls = missing.index_with { |name| resolve(map, name) }
      found, absent = urls.partition { |_, url| url }.map(&:to_h)
      store(found, TTL)
      store(absent, MISSING_TTL)
      urls
    end

    def self.store(urls, expires_in)
      return if urls.empty?

      Rails.cache.write_multi(urls.transform_keys { |name| key_for(name) }, expires_in: expires_in)
    end

    def self.resolve(map, name)
      HOPS.times do
        value = map[name]
        return nil if value.blank?
        return value unless value.start_with?(ALIAS)

        name = value.delete_prefix(ALIAS)
      end
      nil
    end

    def self.all
      map, read_at = @all
      return map if read_at&.after?(LOCAL_TTL.ago)

      Rails.cache.fetch("slack/emoji/all", expires_in: TTL, skip_nil: true) { fetched }
        .tap { |fresh| @all = [fresh, Time.current] }
    end

    def self.fetched
      uri = URI(URL)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError => e
      Rails.logger.warn("slack emoji list unavailable: #{e.message}")
      nil
    end
  end
end
