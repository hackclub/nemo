module FdChannelsHelper
  GUARD_LABELS = {
    Fd::ChannelGuard::BOT_ALLOWLIST => "Bot allow list",
    Fd::ChannelGuard::READONLY => "Read-only",
    Fd::ChannelGuard::SLOWMODE => "Slow mode",
    Fd::ChannelGuard::ACCOUNT_AGE => "New-account age"
  }.freeze

  CHANNEL_TAB_LABELS = {
    "overview" => "Overview",
    "bots" => "Bots",
    "readonly" => "Read-only",
    "slowmode" => "Slow mode",
    "account_age" => "New-account age",
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
      aria: { label: on ? "Turn off" : "Turn on" },
      form: { class: "contents" }
  end

  PURGE_STATE = {
    "proposed" => ["Not confirmed", "state-off"],
    "asked" => ["Waiting", "state-warn"],
    "running" => ["Running", "state-warn"],
    "checking" => ["Checking", "state-warn"],
    "done" => ["Done", "state-good"],
    "failed" => ["Failed", "state-crit"]
  }.freeze

  PURGE_SOURCES = { "slack" => "from Slack", "deactivation" => "with deactivation" }.freeze

  def purge_scope(purge)
    purge.wanted ? "Last #{number_with_delimiter(purge.wanted)}" : "All messages"
  end

  def purge_path(purge)
    return fd_channel_purge_path(purge.channel_id, purge) if purge.channel_id

    fd_member_purge_path(purge.member_id, purge)
  end

  def purge_source(purge)
    PURGE_SOURCES[purge.source]
  end

  def purge_progress(purge)
    purged = number_with_delimiter(purge.purged)
    if purge.waiting?
      return "#{purged} purged" if purge.found.nil?

      return "#{purged} of #{number_with_delimiter(purge.found)} purged"
    end

    parts = ["#{purged} purged"]
    parts << "#{purge.reply_count} in threads" if purge.reply_count.positive?
    unless purge.left_after_check.nil?
      parts << "#{number_with_delimiter(purge.left_after_check)} left after the check"
    end
    parts.join(" · ")
  end

  def purge_state_chip(purge)
    label, tone = PURGE_STATE.fetch(purge.state, [purge.state, "state-off"])
    tag.span(label, class: "state #{tone}")
  end

  def slowmode_line(guard)
    return nil if guard.nil?

    parts = ["#{cooldown_label(guard.seconds)} cooldown", time_left_label(guard.expires_at)]
    parts << "threads" if guard.threads?
    parts.join(" · ")
  end

  def time_left_label(expires_at, now: Time.current)
    expires_at ? "ends #{time_left(expires_at, now: now)}" : "no end date"
  end

  def time_left(expires_at, now: Time.current)
    return "No end" if expires_at.nil?

    seconds = [(expires_at - now).to_i, 0].max
    left =
      if seconds >= 1.day then "#{seconds / 1.day}d #{seconds % 1.day / 1.hour}h"
      elsif seconds >= 1.hour then "#{seconds / 1.hour}h #{seconds % 1.hour / 1.minute}m"
      else "#{[seconds / 1.minute, 1].max}m"
      end
    "in #{left} · #{Fd::ShortDate.ending(expires_at)}"
  end

  def cooldown_label(seconds)
    seconds >= 60 && (seconds % 60).zero? ? "#{seconds / 60}m" : "#{seconds}s"
  end

  def thread_started(guard)
    "Thread · #{Fd::ShortDate.ending(Time.at(guard.thread_ts.to_f).utc)}"
  end

  def thread_slowmode_line(guard)
    parts = ["#{cooldown_label(guard.seconds)} cooldown", time_left_label(guard.expires_at)]
    parts << pluralize(guard.allows.size, "exemption") if guard.allows.any?
    parts << "Reason: #{guard.reason}" if guard.reason.present?
    parts.join(" · ")
  end

  def thread_lock_line(lock)
    parts = [time_left_label(lock.expires_at)]
    parts << "Reason: #{lock.reason}" if lock.reason.present?
    parts.join(" · ")
  end

  def readonly_line(guard, allowed)
    label = allowed.positive? ? "#{pluralize(allowed, 'person')} may post" : "nobody may post"
    guard.threads? ? "#{label}, threads too" : label
  end

  def channel_guard_why(guard)
    return nil if guard.nil?

    safe_join([member_link(guard.opened_by), " · ", on_day(guard.created_at)])
  end

  NEEDS_INVITE = "needs an invite".freeze
  INVITE_NOTE = "Nemo needs an invite to this private channel".freeze

  def needs_invite?(standing)
    standing&.refused? && standing.why == NEEDS_INVITE
  end

  def channel_membership_label(inside, standing)
    return nil if inside
    return membership_note(outside_label(standing), "sev-crit") if inside == false
    return nil if standing.nil? || standing.inside?
    return membership_note("Nemo was removed from this channel", "sev-crit") if standing.verb == "left"
    return membership_note(INVITE_NOTE, "sev-warn") if needs_invite?(standing)

    membership_note(refused_note(standing.why.presence || "refused"), "sev-crit")
  end

  def refused_note(reason)
    "Join failed: #{reason}"
  end

  def membership_note(text, severity)
    tag.p(text.upcase_first, class: severity)
  end

  def offers_nemo_join?(channel_id, standing)
    return false if channel_id.to_s.start_with?("G") || needs_invite?(standing)

    current_account.may?("channel.guard")
  end

  def outside_label(standing)
    return INVITE_NOTE if needs_invite?(standing)

    refusal_reason = standing&.refused? && standing.why.presence
    return refused_note(refusal_reason) if refusal_reason

    "Nemo is not a member of this channel"
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

  def bot_name_link(label, app_id)
    return label if app_id.blank?

    link_to label, "#{MARKETPLACE}/#{app_id}", class: "botlink", target: "_blank", rel: "noopener"
  end

  def guard_face(subject_id)
    avatar(subject_id.to_s.match?(Fd::Names::PERSON) ? subject_id : nil)
  end

  def at_minute(time)
    return "n/a" if time.nil?

    time.in_time_zone(Time.zone).strftime("%-d %b %Y, %H:%M")
  end

  def allow_added_line(allow)
    safe_join(["added by ", member_link(allow.added_by), " ", ago_label(allow.added_at)])
  end
end
