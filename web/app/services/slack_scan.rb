require "net/http"

class SlackScan
  DEFAULT_URL = "https://slackscan.3kh0.net".freeze
  CACHE_TTL = 6.hours
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  Room = Struct.new(:channel_id, :name, :private, keyword_init: true)

  def self.base_url
    ENV["SLACKSCAN_URL"].presence&.chomp("/") || DEFAULT_URL
  end

  def self.channels(user_id)
    return [] if user_id.blank?

    Rails.cache.fetch("slackscan/channels/#{user_id}", expires_in: CACHE_TTL) do
      fetch(user_id)
    end
  end

  def self.fetch(user_id)
    uri = URI.join("#{base_url}/", "users/#{CGI.escape(user_id)}/channels")
    said = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    return [] unless said.is_a?(Net::HTTPSuccess)

    shape(JSON.parse(said.body))
  rescue StandardError => e
    Rails.logger.warn("slackscan: #{e.class} for #{user_id}")
    []
  end

  def self.shape(body)
    Array(body["channels"]).filter_map do |room|
      id = room["channel_id"].presence
      next if id.nil?

      Room.new(channel_id: id, name: room["channel_name"].presence || id,
        private: !!room["is_private"])
    end
  end
end
