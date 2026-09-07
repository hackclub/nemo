module ChannelsHelper
  def channel_query(**overrides)
    base = { q: @q.presence, sort: @sort, direction: @direction,
             view: (@view unless @view == "table"),
             days: @window&.asked,
             match: (@filter.match if @filter&.any?),
             c: (@filter.to_params.values if @filter&.any?),
             measure: (@measure unless @measure == @default_measure),
             cohort: (@cohort&.iso8601 unless @cohort == @default_cohort) }
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
    "Distribution of channels by #{number_with_delimiter(row.measure_total)} " \
      "of #{row.measure_label}"
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

  def slack_channel_url(channel_id)
    "https://app.slack.com/client/#{ENV.fetch("SLACK_TEAM_ID", "T0266FRGM")}/#{channel_id}"
  end
end
