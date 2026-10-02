require "net/http"

module Prometheus
  class Roster
    class Error < StandardError; end
    class Unavailable < Error; end
    class NotConfigured < StandardError; end

    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3

    CHANNELS = "/api/public/v1/users/%s/channels".freeze
    APPOINTMENTS = "/api/public/v1/appointments".freeze
    PAGE_SIZE = 500

    def self.configured?
      ENV["PROMETHEUS_BASE_URL"].present?
    end

    def self.channels_for(user_id)
      body = get(format(CHANNELS, CGI.escape(user_id.to_s)))
      return [] unless body["ok"]

      Array(body["channels"])
    end

    def self.every_appointment
      return enum_for(:every_appointment) unless block_given?

      cursor = nil
      loop do
        body = get(appointments_path(cursor))
        raise Unavailable, "prometheus answered ok:false" unless body["ok"]

        Array(body["appointments"]).each { |one| yield one }
        cursor = body["next_cursor"]
        break if cursor.blank?
      end
    end

    def self.appointments_path(cursor)
      asked = { limit: PAGE_SIZE }
      asked[:cursor] = cursor if cursor.present?
      "#{APPOINTMENTS}?#{asked.to_query}"
    end

    def self.get(path)
      uri = URI.join(base_url, path)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      raise Unavailable, "prometheus answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Unavailable, "prometheus sent something that is not json: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError, IOError, SocketError => e
      raise Unavailable, e.message
    end

    def self.base_url
      ENV["PROMETHEUS_BASE_URL"].presence ||
        raise(NotConfigured, "PROMETHEUS_BASE_URL is not set")
    end
  end
end
