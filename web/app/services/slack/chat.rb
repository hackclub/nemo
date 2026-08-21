require "net/http"

module Slack
  class Chat
    class Unavailable < StandardError; end

    API = "https://slack.com/api".freeze

    def self.post_message(token:, channel:, text:, thread_ts: nil)
      call("chat.postMessage", token, channel: channel, text: text, thread_ts: thread_ts,
        unfurl_links: "false", unfurl_media: "false")
    end

    def self.call(method, token, params)
      uri = URI("#{API}/#{method}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request.set_form_data(params.compact)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: 3, read_timeout: 5) { |http| http.request(request) }
      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError, IOError, SocketError,
           JSON::ParserError => failure
      raise Unavailable, failure.message
    end
  end
end
