require "net/http"

module Slack
  class ProxyClient
    class Error < StandardError; end
    class AuthError < Error; end
    class ApiError < Error; end
    class Unavailable < Error; end

    def self.call(method, params = {}, credential: "internal", read_timeout: 30)
      uri = URI("#{base_url}/call")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{token}"
      request.body = {
        "method" => method,
        "params" => params.compact,
        "credential" => credential
      }.to_json

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: read_timeout) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPBadGateway
        detail = detail_of(response)
        raise detail.to_s.start_with?("invalid_auth") ? AuthError.new(detail) : ApiError.new(detail)
      else
        raise Unavailable, "proxy returned #{response.code}: #{detail_of(response)}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError, IOError, SocketError => e
      raise Unavailable, e.message
    end

    def self.base_url
      ENV.fetch("INTERNAL_PROXY_URL", "http://127.0.0.1:8002")
    end

    def self.token
      ENV.fetch("PROXY_TOKEN_WEB", "")
    end

    def self.detail_of(response)
      JSON.parse(response.body)["detail"]
    rescue StandardError
      nil
    end
  end
end
