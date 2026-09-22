module FdChannelsHelper
  def channel_guard_line(guard)
    return "not guarded" if guard.nil?

    guard.live? ? "guarding" : "lifted"
  end

  def channel_guard_switch(channel_id, guard)
    on = guard.present?
    return holds_mark(on) unless current_account.may?("channel.guard")

    button_to on ? "yes" : "no", fd_channel_guard_path(channel_id),
      method: on ? :delete : :post, class: "switch #{on ? 'yes' : 'no'}",
      title: on ? "stop guarding this channel" : "guard this channel",
      form: { class: "contents" }
  end

  def channel_guard_why(guard)
    return nil if guard.nil?

    said = safe_join([member_link(guard.opened_by), " turned it on ",
                      on_day(guard.created_at)])
    return said if guard.reason.blank?

    safe_join([said, tag.q(guard.reason)], " ")
  end

  def channel_seat_said(standing)
    return nil if standing.nil? || standing.inside?
    return tag.p("nemo was taken out of here", class: "sev-crit") if standing.verb == "left"

    tag.p("nemo could not get in: #{standing.why.presence || 'refused'}", class: "sev-crit")
  end

  MARKETPLACE = "https://hackclub.slack.com/marketplace".freeze

  ACTIVITY_SAID = {
    "kicked" => "put out",
    "deleted" => "message deleted",
    "let_past" => "stayed, we could not put it out"
  }.freeze

  def activity_verb(event)
    said = ACTIVITY_SAID.fetch(event.verb, event.verb)
    return tag.span(said, class: "sev-crit") if event.verb == Fd::ChannelGuardEvent::LET_PAST

    tag.span(said)
  end

  def activity_who(event, labels)
    event.label.presence || labels[event.subject_id].presence || event.subject_id
  end

  def activity_ids(event)
    tag.span([event.subject_id, event.bot_id].compact_blank.uniq.join(" - "), class: "mono")
  end

  def marketplace_link(event)
    return nil if event.app_id.blank?

    link_to "manage this bot", "#{MARKETPLACE}/#{event.app_id}", class: "lnk",
      target: "_blank", rel: "noopener"
  end

  def at_minute(at)
    return "n/a" if at.nil?

    at.in_time_zone(Time.zone).strftime("%-d %b %Y, %H:%M")
  end

  def vouched_line(allow)
    safe_join(["allowed by ", member_link(allow.added_by), " ", ago_label(allow.added_at)])
  end
end
