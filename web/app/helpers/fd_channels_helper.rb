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

    safe_join([member_link(guard.opened_by), " turned it on ", on_day(guard.created_at)])
  end

  def channel_seat_said(seat, standing)
    return nil if seat
    return tag.p(outside_said(standing), class: "sev-crit") if seat == false
    return nil if standing.nil? || standing.inside?
    return tag.p("nemo was taken out of here", class: "sev-crit") if standing.verb == "left"

    tag.p("nemo could not get in: #{standing.why.presence || 'refused'}", class: "sev-crit")
  end

  def outside_said(standing)
    why = standing&.refused? && standing.why.presence
    return "nothing is enforced, nemo could not get in: #{why}" if why

    "nothing is enforced, nemo is not in this channel"
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

  JOIN_MODES = {
    Fd::AppSetting::ON => "Every channel",
    Fd::AppSetting::GUARDED => "Guarded only",
    Fd::AppSetting::OFF => "None"
  }.freeze

  def join_mode_switch(mode)
    unless current_account.may?("channel.guard")
      return tag.div(class: "segmented") { join_mode_options(mode) { |key, label, here|
        tag.span(label, "aria-pressed": here)
      } }
    end

    form_with(url: fd_channel_join_mode_path, method: :post, class: "segmented") do
      join_mode_options(mode) do |key, label, here|
        button_tag(label, name: "mode", value: key, "aria-pressed": here)
      end
    end
  end

  def join_mode_options(mode)
    safe_join(JOIN_MODES.map { |key, label| yield(key, label, (key == mode).to_s) })
  end

  def join_standing_line(joining)
    return "nemo has not swept yet" unless joining.swept?

    said = ["in #{pluralize(joining.seated, 'channel')}"]
    said << "#{joining.waiting} still to join" if joining.waiting.positive?
    said.join(", ")
  end

  def join_unattended_said(joining)
    return nil unless joining.swept? && joining.unattended.positive?

    tag.p("nemo is not in #{pluralize(joining.unattended, 'guarded channel')}",
      class: "sev-crit")
  end

  def vouched_line(allow)
    safe_join(["allowed by ", member_link(allow.added_by), " ", ago_label(allow.added_at)])
  end
end
