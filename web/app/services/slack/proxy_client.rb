require "net/http"

module Slack
  class ProxyClient
    class Error < StandardError; end
    class AuthError < Error; end
    class ApiError < Error; end
    class Unavailable < Error; end
    class NotConfigured < StandardError; end

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

    LOCAL_HOSTS = ["localhost", "127.0.0.1", "::1", "host.docker.internal"].freeze
    TRUTHY = ["1", "true", "yes", "on"].freeze

    def self.base_url
      url = ENV["INTERNAL_PROXY_URL"].presence || raise(NotConfigured, "INTERNAL_PROXY_URL is not set")
      refusal = plaintext_refusal(url)
      raise NotConfigured, refusal if refusal

      url
    end

    def self.plaintext_refusal(url)
      uri = URI(url)
      return nil if uri.scheme == "https" || LOCAL_HOSTS.include?(uri.host)
      return nil if TRUTHY.include?(ENV["PROXY_ALLOW_PLAINTEXT"].to_s.strip.downcase)

      "INTERNAL_PROXY_URL is #{uri.scheme}:// to #{uri.host}, which sends the bearer token in " \
        "clear text over the network. use https, or set PROXY_ALLOW_PLAINTEXT=true if that hop " \
        "is already private"
    end

    def self.token
      ENV["PROXY_TOKEN_WEB"].presence || raise(NotConfigured, "PROXY_TOKEN_WEB is not set")
    end

    def self.detail_of(response)
      JSON.parse(response.body)["detail"]
    rescue StandardError
      nil
    end
  end
end
