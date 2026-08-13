require "net/http"

class CachetClient
  class Error < StandardError; end

  BASE_URL = "https://cachet.hackclub.com".freeze
  CACHE_TTL = 12.hours
  PENDING_TTL = 1.minute
  BATCH = 8
  PENDING = :pending
  MISSING = false

  Profile = Struct.new(:display_name, :image_url, :pronouns, keyword_init: true)

  def self.profile(user_id)
    profiles([user_id])[user_id]
  end

  def self.profiles(user_ids)
    wanted = user_ids.compact.uniq
    return {} if wanted.empty?

    keys = wanted.to_h { |id| [cache_key(id), id] }
    known = Rails.cache.read_multi(*keys.keys).transform_keys { |key| keys.fetch(key) }
    found = known.select { |_, value| value.is_a?(Profile) }

    found.merge(fetch_all(wanted - known.keys))
  end

  def self.fetch_all(user_ids)
    found = {}

    user_ids.each_slice(BATCH) do |slice|
      outcomes = Slack::Analytics.parallel(*slice.map { |id| -> { fetch(id) } })
      slice.zip(outcomes).each do |id, outcome|
        remember(id, outcome)
        found[id] = outcome if outcome.is_a?(Profile)
      end
    end

    found
  end

  def self.remember(user_id, outcome)
    return Rails.cache.write(cache_key(user_id), outcome, expires_in: CACHE_TTL) if
      outcome.is_a?(Profile)

    ttl = outcome == PENDING ? PENDING_TTL : CACHE_TTL
    Rails.cache.write(cache_key(user_id), MISSING, expires_in: ttl)
  end

  def self.cache_key(user_id)
    "cachet/profile/#{user_id}"
  end

  def self.fetch(user_id)
    uri = URI("#{BASE_URL}/users/#{user_id}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3,
      read_timeout: 5) do |http|
      http.get(uri)
    end
    return nil unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    return PENDING if response.code == "202" || body["displayName"] == "Unknown"

    Profile.new(display_name: body["displayName"], image_url: body["imageUrl"],
      pronouns: body["pronouns"])
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError => e
    Rails.logger.error("cachet lookup failed for #{user_id}: #{e.message}")
    nil
  end
end
