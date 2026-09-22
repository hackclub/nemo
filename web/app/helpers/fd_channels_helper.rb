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

  def channel_seat_chip(standing)
    return nil if standing.nil? || standing.inside?
    return tag.span("nemo was taken out of here", class: "chip chip-crit") if standing.verb == "left"

    tag.span("nemo could not get in: #{standing.why.presence || 'refused'}",
      class: "chip chip-crit")
  end

  def vouched_line(allow)
    safe_join(["allowed by ", member_link(allow.added_by), " ", ago_label(allow.added_at)])
  end
end
