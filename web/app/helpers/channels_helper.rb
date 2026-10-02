module ChannelsHelper
  def channel_query(**overrides)
    base = { q: @q.presence, sort: @sort, direction: @direction,
             days: @window&.asked,
             start: @window&.asked_start,
             end: @window&.asked_end,
             match: (@filter.match if @filter&.any?),
             c: (@filter.to_params.values if @filter&.any?),
             measure: (@measure unless @measure == @default_measure),
             cohort: (@cohort&.iso8601 unless @cohort == @default_cohort),
             newcomers: (@newcomer_cohort&.key unless @newcomer_cohort&.default?) }
    channels_path(**base.merge(overrides).compact)
  end

  def channels_window_note(total, window)
    said = "#{number_with_delimiter(total)} channels"
    return said if window.nil?

    messages = window_note(window.start_date, window.end_date)
    return said if messages.nil?
    return "#{said} · #{messages}" if window.pulled?

    people = window_note(window.pulled_start, window.pulled_end)
    "#{said} · messages #{messages}#{" · people #{people}" if people}"
  end

  def channels_empty_title
    return "No channel matches that search" if @q.present?
    return "No channel matches those conditions" if @filter&.any?
    return "No channel is shared with you" if @mine_total.to_i.zero?

    "No channel yet"
  end

  def backfill_cost(channel, estimate, ceiling)
    lines = ["Fetch thread replies for ##{channel.name}?",
             "About #{number_with_delimiter(estimate)} requests to Slack."]
    lines << "That is over the #{number_with_delimiter(ceiling)} request line." if estimate > ceiling
    lines.join(" ")
  end

  def band_title(row)
    "Distribution by #{number_with_delimiter(row.measure_total)} " \
      "of #{row.measure_label}"
  end

  FUNNEL_SHORT = {
    "landed" => "first post",
    "answered" => "got a reply",
    "fast" => "fast reply",
    "returned" => "came back"
  }.freeze

  def funnel_step_said(step)
    FUNNEL_SHORT.fetch(step.key, step.label)
  end

  def latency_bucket_said(bucket)
    bucket.to_s.sub(/\Aunder /, "<").sub(/\Aover /, ">").gsub(" to ", "-")
  end

  def channel_sort_th(label, column, css = nil)
    active = @sort == column
    next_direction = active ? (@direction == "asc" ? "desc" : "asc") : "desc"
    arrow = active ? (@direction == "asc" ? " &uarr;" : " &darr;") : ""
    sort_state = active ? (@direction == "asc" ? "ascending" : "descending") : "none"

    tag.th(class: css, **{ "aria-sort": sort_state }) do
      link_to safe_join([label, arrow.html_safe]),
        channel_query(sort: column, direction: next_direction),
        class: "sortable", data: { turbo_frame: "channels" }
    end
  end

  def channel_read_ratio(read, posted)
    return "n/a" if read.nil? || posted.to_i.zero?

    (read.to_f / posted).round(1)
  end

  def channel_change_cell(channel)
    if channel.try(:prior_thin)
      return tag.span("n/a", class: "sub2",
        title: "the previous window held #{number_with_delimiter(channel.prior_messages)} " \
               "member messages, under the floor of #{number_with_delimiter(channel.prior_floor)}")
    end

    change = channel.try(:range_change)
    return tag.span("n/a", class: "sub2") if change.nil?

    change = change.to_f
    tone = change.positive? ? "delta-up" : change.negative? ? "delta-down" : "share"
    tag.span("#{change.positive? ? '+' : ''}#{number_to_percentage(change, precision: 1)}",
      class: tone,
      title: "#{number_with_delimiter(channel.range_messages)} member messages against " \
             "#{number_with_delimiter(channel.prior_messages)} in the window before")
  end

  def slack_window_said(range, from, to)
    stats = range&.stats || {}
    lo = Channels::Window.on(stats["start_date"]) || from
    hi = Channels::Window.on(stats["end_date"]) || to
    window_note(lo, hi)
  end

  def channel_voice_tone(channel)
    return "" if channel.range_posters.nil? || channel.range_members.to_i.zero?

    share = channel.range_posters.to_f / channel.range_members * 100
    return "is-loud" if share > 10
    return "is-quiet" if share < 2

    ""
  end

  def viewable_channel_ids
    @viewable_channel_ids ||=
      Channels::Audience.for(current_account).pluck(:channel_id).to_set
  end

  def channel_name_cell(channel_id, name)
    label = tag.b("##{name}")
    return label unless viewable_channel_ids.include?(channel_id)

    link_to(label, channel_path(channel_id))
  end

  def channel_spoke_share(posted, members)
    return "n/a" if posted.nil? || members.to_i.zero?

    number_to_percentage(posted.to_f / members * 100, precision: 1)
  end

  TENURE_INK = { "under_90d" => 1, "under_1y" => 2, "under_3y" => 3,
                 "over_3y" => 4, "unknown" => 0 }.freeze

  def channel_view_path(**overrides)
    base = { view: (@view unless @view == ChannelsController::DEFAULT_VIEW),
             days: (@range_preset unless @range_preset == ChannelsController::DEFAULT_RANGE_DAYS),
             start: (@start_date if @range_preset.nil?),
             end: (@end_date if @range_preset.nil?),
             month: (@crowd&.month&.iso8601 unless @crowd&.month == @crowd&.months&.first) }
    said = base.merge(overrides)
    said[:view] = nil if said[:view] == ChannelsController::DEFAULT_VIEW
    said = said.except(:start, :end) if said[:days]
    said = said.except(:days) if said[:start] || said[:end]
    channel_path(@channel, **said.compact)
  end

  def pulse_delta(pct, said = nil)
    return tag.span("n/a", class: "sub2") if pct.nil?

    tone = pct.positive? ? "delta-up" : pct.negative? ? "delta-down" : "delta-share"
    text = "#{pct.positive? ? '+' : ''}#{number_to_percentage(pct, precision: 1)}"
    safe_join([tag.span(text, class: tone), said].compact, " ")
  end

  def duration_said(seconds)
    return "n/a" if seconds.nil?

    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600
    return "#{seconds / 3600}h #{(seconds % 3600) / 60}m" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  def tenure_ink(band)
    "ser-#{TENURE_INK.fetch(band, 0)}"
  end

  COMPOSITION_INK = { "spoke" => "ser-1", "read" => "ser-2", "never" => "ser-none" }.freeze

  def composition_ink(key)
    COMPOSITION_INK.fetch(key, "ser-0")
  end

  def channel_standing(standing)
    return nil if standing.nil? || standing.rank.nil?

    active = standing.active_channels.to_i
    return nil unless active.positive?

    { rank: standing.rank, of: active,
      percentile: (100 - ((standing.rank - 1) * 100.0 / active)).floor }
  end

  def concentration_points(curve)
    curve.map { |point| [point.poster_pct, point.message_pct.to_f] }
  end

  def channels_range_said(window)
    return window_note(window.start_date, window.end_date) if window.custom?
    return "All measured" if window.pulled?

    "Last #{window.days} days"
  end

  def range_said(preset, from, to)
    return "Last #{preset} days" if preset

    window_note(from, to)
  end

  def said_ago(at)
    return nil if at.nil?

    gap = (Time.current - at).to_i
    return "just now" if gap < 60
    return "#{gap / 60} min ago" if gap < 3600
    return "#{gap / 3600}h ago" if gap < 86_400
    return "#{gap / 86_400}d ago" if gap < 2_592_000

    at.to_date.strftime("%-d %b %Y")
  end

  def channel_age(created)
    return nil if created.nil?

    months = ((Date.current.year * 12 + Date.current.month) -
              (created.year * 12 + created.month))
    years, rest = months.divmod(12)
    return "#{years}y #{rest}m" if years.positive?

    "#{rest}m"
  end

  def slack_channel_url(channel_id)
    "https://app.slack.com/client/#{ENV.fetch("SLACK_TEAM_ID", "T0266FRGM")}/#{channel_id}"
  end
end
