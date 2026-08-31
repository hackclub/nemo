module ChannelsHelper
  def channel_query(**overrides)
    base = { q: @q.presence, sort: @sort, direction: @direction,
             view: (@view unless @view == "table"), f: @filters.presence,
             measure: (@measure unless @measure == @default_measure) }
    channels_path(**base.merge(overrides).compact)
  end

  def channel_sort_th(label, column, css = nil)
    active = @sort == column
    next_direction = active ? (@direction == "asc" ? "desc" : "asc") : "desc"
    arrow = active ? (@direction == "asc" ? " &uarr;" : " &darr;") : ""
    sort_state = active ? (@direction == "asc" ? "ascending" : "descending") : "none"

    tag.th(class: css, **{ "aria-sort": sort_state }) do
      link_to safe_join([label, arrow.html_safe]),
        channel_query(sort: column, direction: next_direction),
        class: "sortable"
    end
  end

  def channel_filter_options
    ChannelsController::FILTERS.reject { |key, _| @filters.include?(key) }
  end

  def channel_read_ratio(read, posted)
    return "n/a" if read.nil? || posted.to_i.zero?

    (read.to_f / posted).round(1)
  end

  def channel_voice(channel)
    return "n/a" if channel.range_posters.nil? || channel.range_members.to_i.zero?

    number_to_percentage(channel.range_posters.to_f / channel.range_members * 100, precision: 1)
  end

  def channel_voice_tone(channel)
    return "" if channel.range_posters.nil? || channel.range_members.to_i.zero?

    share = channel.range_posters.to_f / channel.range_members * 100
    return "is-loud" if share > 10
    return "is-quiet" if share < 2

    ""
  end

  def channel_spoke_share(posted, members)
    return "n/a" if posted.nil? || members.to_i.zero?

    number_to_percentage(posted.to_f / members * 100, precision: 1)
  end

  def slack_channel_url(channel_id)
    "https://app.slack.com/client/#{ENV.fetch("SLACK_TEAM_ID", "T0266FRGM")}/#{channel_id}"
  end
end
