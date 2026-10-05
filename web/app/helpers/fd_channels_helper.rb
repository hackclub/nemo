module FdChannelsHelper
  def channel_guard_line(guard)
    return "not guarded" if guard.nil?

    guard.live? ? "guarding" : "lifted"
  end

  GUARD_LABELS = {
    Fd::ChannelGuard::BOT_ALLOWLIST => "Bot allow list",
    Fd::ChannelGuard::READONLY => "Read-only",
    Fd::ChannelGuard::SLOWMODE => "Slow mode",
    Fd::ChannelGuard::ACCOUNT_AGE => "New accounts"
  }.freeze

  CHANNEL_TAB_LABELS = {
    "overview" => "Overview",
    "bots" => "Bots",
    "readonly" => "Read-only",
    "slowmode" => "Slow mode",
    "account_age" => "New accounts",
    "purge" => "Purge"
  }.freeze

  def channel_tab_label(key)
    CHANNEL_TAB_LABELS.fetch(key) { key.tr("_", " ").capitalize }
  end

  def guard_label(kind)
    GUARD_LABELS.fetch(kind, kind)
  end

  def guard_tab(kind)
    Fd::ChannelsController::KIND_TABS.fetch(kind, "overview")
  end

  def guard_setting_label(guard, allowed)
    case guard.kind
    when Fd::ChannelGuard::SLOWMODE then slowmode_line(guard)
    when Fd::ChannelGuard::ACCOUNT_AGE then "#{pluralize(guard.min_age_days, 'day')} old to post"
    when Fd::ChannelGuard::BOT_ALLOWLIST
      allowed.positive? ? "#{pluralize(allowed, 'bot')} allowed" : "no bot allowed"
    when Fd::ChannelGuard::READONLY
      readonly_line(guard, allowed)
    end
  end

  def channel_guard_switch(channel_id, guard, kind: Fd::ChannelGuard::BOT_ALLOWLIST)
    on = guard.present?
    return nil unless current_account.may?("channel.guard")

    button_to on ? "yes" : "no", fd_channel_guard_path(channel_id, kind),
      method: on ? :delete : :post, class: "switch #{on ? 'yes' : 'no'}",
      title: on ? "turn it off" : "turn it on",
      aria: { label: on ? "turn it off" : "turn it on" },
      form: { class: "contents" }
  end

  PURGE_STATE = {
    "asked" => ["waiting", "state-warn"],
    "running" => ["running", "state-warn"],
    "done" => ["done", "state-good"],
    "failed" => ["failed", "state-crit"]
  }.freeze

  def purge_state_chip(purge)
    label, tone = PURGE_STATE.fetch(purge.state, [purge.state, "state-off"])
    tag.span(label, class: "state #{tone}")
  end

  def slowmode_line(guard)
    return nil if guard.nil?

    label = "#{pluralize(guard.seconds, 'second')} between messages"
    guard.threads? ? "#{label}, threads too" : label
  end

  def readonly_line(guard, allowed)
    label = allowed.positive? ? "#{pluralize(allowed, 'person')} may post" : "nobody may post"
    guard.threads? ? "#{label}, threads too" : label
  end

  def channel_guard_why(guard)
    return nil if guard.nil?

    safe_join([member_link(guard.opened_by), " turned it on ", on_day(guard.created_at)])
  end

  NEEDS_INVITE = "needs an invite".freeze
  INVITE_NOTE = "a human has to /invite nemo here, a bot cannot join a private channel".freeze

  def needs_invite?(standing)
    standing&.refused? && standing.why == NEEDS_INVITE
  end

  def channel_seat_label(seat, standing)
    return nil if seat
    return tag.p(outside_label(standing), class: "sev-crit") if seat == false
    return nil if standing.nil? || standing.inside?
    return tag.p("nemo was taken out of here", class: "sev-crit") if standing.verb == "left"
    return tag.p(INVITE_NOTE, class: "sev-warn") if needs_invite?(standing)

    tag.p("nemo could not get in: #{standing.why.presence || 'refused'}", class: "sev-crit")
  end

  def outside_label(standing)
    return "nothing is enforced, #{INVITE_NOTE}" if needs_invite?(standing)

    why = standing&.refused? && standing.why.presence
    return "nothing is enforced, nemo could not get in: #{why}" if why

    "nothing is enforced, nemo is not in this channel"
  end

  MARKETPLACE = "https://hackclub.slack.com/marketplace".freeze

  ACTIVITY_LABELS = {
    "kicked" => ["removed", "state-warn"],
    "deleted" => ["deleted", "state-warn"],
    "let_past" => ["not removed", "state-crit"]
  }.freeze

  def activity_verb(event)
    label, tone = ACTIVITY_LABELS.fetch(event.verb, [event.verb, "state-off"])
    tag.span(label, class: "state #{tone}")
  end

  def activity_who(event, labels)
    event.label.presence || labels[event.subject_id].presence || event.subject_id
  end

  def activity_ids(event)
    tag.span([event.subject_id, event.bot_id].compact_blank.uniq.join(" - "), class: "mono")
  end

  def marketplace_link(app_id, label = "manage this bot")
    return nil if app_id.blank?

    link_to label, "#{MARKETPLACE}/#{app_id}", class: "lnk lnk-soft",
      target: "_blank", rel: "noopener"
  end

  def bot_name_link(label, app_id)
    return label if app_id.blank?

    link_to label, "#{MARKETPLACE}/#{app_id}", class: "botlink",
      title: "open #{label} in the Slack marketplace", target: "_blank", rel: "noopener"
  end

  def guard_face(subject_id)
    face(subject_id.to_s.match?(Fd::Names::PERSON) ? subject_id : nil)
  end

  def at_minute(at)
    return "n/a" if at.nil?

    at.in_time_zone(Time.zone).strftime("%-d %b %Y, %H:%M")
  end

  def vouched_line(allow)
    safe_join(["allowed by ", member_link(allow.added_by), " ", ago_label(allow.added_at)])
  end
end
