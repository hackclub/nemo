module FdChannelsHelper
  def channel_guard_line(guard)
    return "not guarded" if guard.nil?

    guard.live? ? "guarding" : "lifted"
  end

  def channel_guard_why(guard, names)
    return nil if guard.nil?

    who = names[guard.opened_by].presence || "@#{guard.opened_by}"
    safe_join([
      tag.b(who), " turned it on ", on_day(guard.created_at),
      (guard.reason.present? ? tag.q(guard.reason) : nil)
    ].compact, " ")
  end

  def channel_seat_word(standing)
    return "unknown" if standing.nil?
    return "in" if standing.inside?
    return "out" if standing.verb == "left"

    standing.why.presence || "refused"
  end

  def channel_seat_tone(standing)
    return "is-none" if standing.nil? || !standing.inside?

    nil
  end

  def vouched_line(allow, names)
    who = names[allow.added_by].presence || "@#{allow.added_by}"
    "allowed by #{who} #{ago_label(allow.added_at)}"
  end
end
