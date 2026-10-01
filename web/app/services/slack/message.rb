module Slack
  class Message
    METHOD = "conversations.history".freeze
    TTL = 10.minutes

    Result = Struct.new(:said, :error, keyword_init: true) do
      def found? = said.present?
    end

    def self.at(channel_id, ts)
      said = Rails.cache.fetch(key_for(channel_id, ts), expires_in: TTL, skip_nil: true) do
        asked(channel_id, ts)
      end
      return Result.new(error: :not_found) if said.nil?

      Result.new(said: said)
    rescue ProxyClient::NotConfigured => e
      Rails.logger.error("slack message proxy is not configured: #{e.message}")
      Result.new(error: :not_configured)
    rescue ProxyClient::AuthError
      Result.new(error: :reauth)
    rescue ProxyClient::Error
      Result.new(error: :unavailable)
    end

    def self.key_for(channel_id, ts) = "slack/message/#{channel_id}/#{ts}"

    def self.asked(channel_id, ts)
      answer = ProxyClient.call(METHOD, {
        "channel" => channel_id, "latest" => ts, "oldest" => ts,
        "inclusive" => true, "limit" => 1
      }, credential: "admin")
      return nil unless answer["ok"]

      found = (answer["messages"] || []).first
      found if found && found["ts"] == ts
    end
  end
end
