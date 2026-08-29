module ChannelsHelper
  def channel_sort_th(label, column, css = nil)
    active = @sort == column
    next_direction = active ? (@direction == "asc" ? "desc" : "asc") : "desc"
    arrow = active ? (@direction == "asc" ? " &uarr;" : " &darr;") : ""
    sort_state = active ? (@direction == "asc" ? "ascending" : "descending") : "none"

    tag.th(class: css, **{ "aria-sort": sort_state }) do
      link_to safe_join([label, arrow.html_safe]),
        channels_path(sort: column, direction: next_direction, q: @q.presence),
        class: "sortable"
    end
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
