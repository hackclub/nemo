module Messages
  class Activity
    METHOD = "insights.messageStats".freeze
    TTL = 1.minute

    SPANS = {
      "1h" => "First hour",
      "1d" => "First day",
      "1w" => "First week",
      "30d" => "First month"
    }.freeze
    DEFAULT_SPAN = "1d".freeze

    UNITS = {
      "1h" => [60, ->(n) { "#{n}m" }],
      "1d" => [3600, ->(n) { "#{n}h" }],
      "1w" => [86_400, ->(n) { "day #{n}" }],
      "30d" => [86_400, ->(n) { "day #{n}" }]
    }.freeze

    AXIS = {
      "1h" => "minutes after posting",
      "1d" => "hours after posting",
      "1w" => "days after posting",
      "30d" => "days after posting"
    }.freeze

    VIEWERS = "new viewers".freeze

    CLIENTS = [["browser_count", "browser"], ["desktop_count", "desktop"],
               ["mobile_count", "mobile"]].freeze

    Result = Struct.new(:stats, :error, keyword_init: true)

    def self.for(channel_id, ts, posted_at: nil)
      stats = Rails.cache.fetch("slack/activity/#{channel_id}/#{ts}", expires_in: TTL,
                                                                    skip_nil: true) do
        response = Slack::ProxyClient.call(METHOD, { "channel" => channel_id, "ts" => ts })
        response["stats"] if response["ok"]
      end
      return Result.new(error: :not_found) if stats.nil?

      Result.new(stats: new(stats, posted_at: posted_at))
    rescue Slack::ProxyClient::NotConfiguredError => e
      Rails.logger.error("message activity proxy is not configured: #{e.message}")
      Result.new(error: :not_configured)
    rescue Slack::ProxyClient::AuthError
      Result.new(error: :reauth)
    rescue Slack::ProxyClient::Error
      Result.new(error: :unavailable)
    end

    def self.x_label(span) = AXIS.fetch(span, AXIS[DEFAULT_SPAN])

    def self.span_for(posted_at)
      age = Time.current - posted_at
      return "1h" if age < 2.hours
      return "1d" if age < 2.days
      return "1w" if age < 8.days

      "30d"
    end

    def initialize(stats, posted_at: nil)
      @stats = stats
      @posted_at = posted_at
    end

    def age = @posted_at ? (Time.current - @posted_at).to_i : nil

    def viewers = @stats["num_users_viewed"].to_i
    def reacted = @stats["num_users_reacted"].to_i
    def clicked = @stats["num_users_clicked"].to_i
    def shared = @stats["num_shares"].to_i
    def top_reply_ts = @stats["top_threaded_reply_by_reactions_ts"].presence

    def clients
      counts = CLIENTS.map { |key, label| [label, (@stats["client_breakdown"] || {})[key].to_i] }
      whole = counts.sum { |_, count| count }
      counts.map { |label, count| [label, count, whole.zero? ? nil : (100.0 * count / whole).round] }
    end

    DAILY = { "VIEWS" => "views", "CLICKS" => "clicks", "REACTIONS" => "reactions" }.freeze

    BUCKETS = [[3600, "hour"], [60, "minute"]].freeze

    def curve(span)
      series = ((@stats["viewers_time_series"] || {})["data"] || [])
        .find { |one| one["seriesType"] == span }
      return [] if series.nil?

      points = (series["series"] || []).filter_map do |point|
        next if point["value"].nil?

        [point["value"].to_i / 1_000_000, point["count"].to_i]
      end
      return [] if points.empty?

      start = points.first.first
      points.map { |at, count| [at - start, count] }
        .reject { |offset, _| age && offset > age }
    end

    def stamps(span)
      series = ((@stats["viewers_time_series"] || {})["data"] || [])
        .find { |one| one["seriesType"] == span }
      (series && series["series"] || []).filter_map { |one| one["value"]&.to_i&./(1_000_000) }
    end

    def bucket_seconds(span)
      held = stamps(span)
      held.size > 1 ? held[1] - held[0] : nil
    end

    def window_seconds(span)
      held = stamps(span)
      held.size > 1 ? held.last - held.first : nil
    end

    def bucket_label(span)
      seconds = bucket_seconds(span)
      return nil if seconds.nil?

      size, word = BUCKETS.find { |step, _| seconds >= step } || [1, "second"]
      "#{(seconds.to_f / size).round}-#{word}"
    end

    def partial?(span)
      whole = window_seconds(span)
      age.present? && whole.present? && age < whole
    end

    def seen_within(span) = curve(span).sum(&:last)

    def any_curve? = SPANS.keys.any? { |span| curve(span).size > 1 }

    def chart(span)
      unit, say = UNITS.fetch(span)
      points = curve(span)
      {
        labels: points.map { |offset, _| say.call((offset / unit.to_f).round(1).then { |n| n == n.to_i ? n.to_i : n }) },
        datasets: [{ label: "new viewers", data: points.map(&:last) }]
      }
    end

    def peak(span)
      curve(span).max_by(&:last)&.last.to_i
    end

    def daily
      given = Array(@stats["activity_time_series"])
      held = DAILY.keys.to_h do |key|
        found = given.find { |one| one["seriesType"] == key }
        [key, (found && found["series"] || [])]
      end
      stamps = held.values.max_by(&:size).to_a

      stamps.each_with_index.map do |point, i|
        [Time.zone.at(point["value"].to_i / 1_000_000).to_date,
         DAILY.keys.map { |key| held[key][i] && held[key][i]["count"].to_i }]
      end
    end

    def daily?
      rows = daily
      rows.size > 1 && rows.sum { |_, counts| counts.compact.sum }.positive?
    end

    def daily_chart
      rows = daily
      {
        labels: rows.map { |day, _| day.iso8601 },
        datasets: DAILY.values.each_with_index.map do |label, i|
          { label: label, data: rows.map { |_, counts| counts[i] } }
        end
      }
    end
  end
end
