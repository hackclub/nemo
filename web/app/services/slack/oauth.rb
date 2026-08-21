require "net/http"

module Slack
  class Oauth
    class NotConfigured < StandardError; end
    class Unavailable < StandardError; end
    class Refused < StandardError; end

    AUTHORIZE = "https://slack.com/oauth/v2/authorize".freeze
    API = "https://slack.com/api".freeze

    def self.configured?
      client_id.present? && client_secret.present?
    end

    def self.walk_to(redirect_uri:, state:)
      raise NotConfigured, "NEMO_CLIENT_ID and NEMO_CLIENT_SECRET are not set" unless configured?

      query = { client_id: client_id, user_scope: Fd::StaffSlack::SCOPE,
                redirect_uri: redirect_uri, state: state }
      "#{AUTHORIZE}?#{query.to_query}"
    end

    def self.exchange(code:, redirect_uri:)
      raise NotConfigured, "NEMO_CLIENT_ID and NEMO_CLIENT_SECRET are not set" unless configured?

      answer = call("oauth.v2.access", client_id: client_id, client_secret: client_secret,
        code: code, redirect_uri: redirect_uri)
      raise Refused, answer["error"].to_s.presence || "slack refused it" unless answer["ok"]

      answer
    end

    def self.give_back(token)
      call("auth.revoke", {}, token)
    rescue Unavailable
      { "ok" => false, "error" => "unreachable" }
    end

    def self.call(method, params, token = nil)
      uri = URI("#{API}/#{method}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}" if token
      request.set_form_data(params.compact)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError, IOError, SocketError,
           JSON::ParserError => failure
      raise Unavailable, failure.message
    end

    def self.client_id
      ENV["NEMO_CLIENT_ID"].presence
    end

    def self.client_secret
      ENV["NEMO_CLIENT_SECRET"].presence
    end

    def self.workspace
      ENV["SLACK_TEAM_ID"].presence
    end
  end
end
