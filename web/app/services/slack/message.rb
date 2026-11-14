module Slack
  class Message
    METHOD = "conversations.history".freeze
    REPLIES_METHOD = "conversations.replies".freeze
    TTL = 10.minutes

    Result = Struct.new(:message, :error, keyword_init: true) do
      def message? = message.present?
    end

    def self.at(channel_id, ts, thread_ts: nil)
      message = Rails.cache.fetch(key_for(channel_id, ts), expires_in: TTL, skip_nil: true) do
        fetch_message(channel_id, ts, thread_ts)
      end
      return Result.new(error: :not_found) if message.nil?

      Result.new(message: message)
    rescue ProxyClient::NotConfiguredError => e
      Rails.logger.error("slack message proxy is not configured: #{e.message}")
      Result.new(error: :not_configured)
    rescue ProxyClient::AuthError
      Result.new(error: :reauth)
    rescue ProxyClient::Error
      Result.new(error: :unavailable)
    end

    def self.key_for(channel_id, ts) = "slack/message/#{channel_id}/#{ts}"

    def self.fetch_message(channel_id, ts, thread_ts = nil)
      return fetch_reply(channel_id, ts, thread_ts) if thread_ts.present? && thread_ts != ts

      response = ProxyClient.call(METHOD, {
        "channel" => channel_id, "latest" => ts, "oldest" => ts,
        "inclusive" => true, "limit" => 1
      }, credential: "admin")
      return nil unless response["ok"]

      message = (response["messages"] || []).first
      message if message && message["ts"] == ts
    end

    def self.fetch_reply(channel_id, ts, thread_ts)
      response = ProxyClient.call(REPLIES_METHOD, {
        "channel" => channel_id, "ts" => thread_ts, "latest" => ts, "oldest" => ts,
        "inclusive" => true, "limit" => 2
      }, credential: "admin")
      return nil unless response["ok"]

      (response["messages"] || []).find { |message| message["ts"] == ts }
    end
  end
end
