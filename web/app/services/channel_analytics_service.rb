require "net/http"

class ChannelAnalyticsService
  BASE_URL = ENV.fetch("CHANNEL_ANALYTICS_URL", "http://127.0.0.1:8001")
  Result = Struct.new(:stats, :error, keyword_init: true)

  def self.fetch(channel_id:, name:, start_date:, end_date:, privacy: "public")
    uri = URI("#{BASE_URL}/channel-analytics")
    uri.query = URI.encode_www_form(
      channel_id: channel_id, name: name,
      start: start_date.to_s, end: end_date.to_s, privacy: privacy
    )
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end

    case response
    when Net::HTTPSuccess then Result.new(stats: JSON.parse(response.body))
    when Net::HTTPServiceUnavailable then Result.new(error: :reauth)
    when Net::HTTPNotFound then Result.new(error: :not_found)
    else Result.new(error: :unavailable)
    end
  rescue StandardError
    Result.new(error: :unavailable)
  end

  def self.available_range
    uri = URI("#{BASE_URL}/available-range")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
  rescue StandardError
    nil
  end

  def self.member_count(channel_id:)
    uri = URI("#{BASE_URL}/channel-members")
    uri.query = URI.encode_www_form(channel_id: channel_id)
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body)["num_members"] : nil
  rescue StandardError
    nil
  end
end
