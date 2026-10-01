require "net/http"

module Slack
  class Emoji
    URL = "https://badger.hackclub.dev/api/emoji".freeze
    TTL = 12.hours
    MISSING_TTL = 1.hour
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    ALIAS = "alias:".freeze
    HOPS = 3

    def self.for(names)
      wanted = Array(names).map(&:to_s).reject(&:empty?).uniq
      return {} if wanted.empty?

      held = wanted.index_with { |name| Rails.cache.read(key_for(name)) }
      missing = wanted.reject { |name| Rails.cache.exist?(key_for(name)) }
      held = held.merge(looked_up(missing)) if missing.any?
      held.compact
    end

    def self.key_for(name) = "slack/emoji/#{name}"

    def self.looked_up(missing)
      map = all
      return missing.index_with { nil } if map.nil?

      missing.index_with do |name|
        found = resolve(map, name)
        Rails.cache.write(key_for(name), found, expires_in: found ? TTL : MISSING_TTL)
        found
      end
    end

    def self.resolve(map, name)
      HOPS.times do
        found = map[name]
        return nil if found.blank?
        return found unless found.start_with?(ALIAS)

        name = found.delete_prefix(ALIAS)
      end
      nil
    end

    def self.all
      Rails.cache.fetch("slack/emoji/all", expires_in: TTL, skip_nil: true) { fetched }
    end

    def self.fetched
      uri = URI(URL)
      answer = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                               open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      return nil unless answer.is_a?(Net::HTTPSuccess)

      found = JSON.parse(answer.body)
      found.is_a?(Hash) ? found : nil
    rescue StandardError => e
      Rails.logger.warn("slack emoji list unavailable: #{e.message}")
      nil
    end
  end
end
