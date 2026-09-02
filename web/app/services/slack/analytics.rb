module Slack
  class Analytics
    SEARCH_PAGE = 1000
    COVERAGE_TTL = 1.hour
    CHANNEL_TTL = 6.hours

    Result = Struct.new(:stats, :error, keyword_init: true)

    def self.coverage
      Rails.cache.fetch("slack/analytics/coverage", expires_in: COVERAGE_TTL, skip_nil: true) do
        response = ProxyClient.call("admin.analytics.getAvailableDateRange", { "type" => "member" })
        from = response["start_date"]
        to = response["end_date"]
        { "start_date" => from, "end_date" => to } if from.present? && to.present?
      end
    rescue ProxyClient::NotConfigured => e
      Rails.logger.error("slack analytics proxy is not configured: #{e.message}")
      nil
    rescue ProxyClient::Error
      nil
    end

    def self.parallel(*tasks)
      tasks
        .map { |task| Thread.new { Rails.application.executor.wrap { task.call } } }
        .map(&:value)
    end

    def self.channel_activity(channel_id:, name:, from:, to:, privacy: "public")
      from, to = clamp(from, to)
      key = channel_key(channel_id, from, to, privacy)
      held = Rails.cache.read(key)
      return Result.new(stats: held) if held

      asked(channel_id: channel_id, name: name, from: from, to: to, privacy: privacy).tap do |got|
        Rails.cache.write(key, got.stats, expires_in: CHANNEL_TTL) if got.stats
      end
    end

    def self.channel_key(channel_id, from, to, privacy)
      "slack/analytics/channel/#{channel_id}/#{from}/#{to}/#{privacy}"
    end

    def self.asked(channel_id:, name:, from:, to:, privacy:)
      response = ProxyClient.call("admin.analytics.getChannelAnalytics", {
        "start_date" => from,
        "end_date" => to,
        "count" => SEARCH_PAGE,
        "query" => name,
        "privacy" => privacy,
        "sort_column" => "messages_count",
        "sort_direction" => "desc"
      })

      records = response["channel_analytics"] || []
      match = records.find { |channel| channel["channel_id"] == channel_id }
      return Result.new(stats: shape(match, from, to)) if match

      Result.new(error: response["num_found"].to_i > records.size ? :truncated : :not_found)
    rescue ProxyClient::NotConfigured => e
      Rails.logger.error("slack analytics proxy is not configured: #{e.message}")
      Result.new(error: :not_configured)
    rescue ProxyClient::AuthError
      Result.new(error: :reauth)
    rescue ProxyClient::Error
      Result.new(error: :unavailable)
    end

    def self.clamp(from, to)
      window = coverage
      return [from.to_s, to.to_s] unless window

      [[from.to_s, window["start_date"]].max, [to.to_s, window["end_date"]].min]
    end

    def self.shape(channel, from, to)
      {
        "channel_id" => channel["channel_id"],
        "name" => channel["name"],
        "start_date" => from,
        "end_date" => to,
        "messages_count" => channel["messages_count"],
        "chats_count" => channel["chats_count"],
        "reactions_count" => channel["reactions_count"],
        "unique_posters" => channel["writers_count"],
        "unique_viewers" => channel["readers_count"],
        "unique_reactors" => channel["users_who_reacted_count"],
        "huddles_count" => channel["huddles_count"],
        "total_members_count" => channel["total_members_count"]
      }
    end
  end
end
