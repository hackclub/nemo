require "net/http"

class CachetClient
  class Error < StandardError; end

  BASE_URL = "https://cachet.hackclub.com".freeze
  CACHE_TTL = 12.hours

  Profile = Struct.new(:display_name, :image_url, :pronouns, keyword_init: true)

  def self.profile(user_id)
    Rails.cache.fetch("cachet/profile/#{user_id}", expires_in: CACHE_TTL) do
      fetch(user_id)
    end
  end

  def self.fetch(user_id)
    uri = URI("#{BASE_URL}/users/#{user_id}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) do |http|
      http.get(uri)
    end
    return nil unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    return nil if body["displayName"] == "Unknown"

    Profile.new(display_name: body["displayName"], image_url: body["imageUrl"], pronouns: body["pronouns"])
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError => e
    Rails.logger.error("cachet lookup failed for #{user_id}: #{e.message}")
    nil
  end
end
