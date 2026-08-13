module FdHelper
  AGE_WARN = 2.days
  AGE_CRIT = 5.days

  def case_age_seconds(kase)
    (kase.resolved_at || Time.current) - kase.opened_at
  end

  def case_age_chip(kase)
    seconds = case_age_seconds(kase)
    tone = kase.resolved? ? "chip-off" : age_tone(seconds)
    tag.span(case_age_label(seconds), class: "chip #{tone}")
  end

  def case_severity(kase)
    return "sev-calm" if kase.resolved?

    case age_tone(case_age_seconds(kase))
    when "chip-crit" then "sev-crit"
    when "chip-warn" then "sev-warn"
    else "sev-calm"
    end
  end

  def age_tone(seconds)
    return "chip-crit" if seconds >= AGE_CRIT
    return "chip-warn" if seconds >= AGE_WARN

    "chip-off"
  end

  def case_age_label(seconds)
    days = (seconds / 1.day).floor
    return "#{days}d" if days.positive?

    hours = (seconds / 1.hour).floor
    return "#{hours}h" if hours.positive?

    "#{(seconds / 1.minute).floor}m"
  end

  def tenure_label(days)
    return "n/a" if days.nil?
    return "#{days}d" if days < 31

    months = days / 30
    return "#{months}mo" if months < 12

    years, rest = months.divmod(12)
    rest.zero? ? "#{years}y" : "#{years}y #{rest}mo"
  end

  ROLE_LABELS = {
    "subject" => "the case is about them",
    "reporter" => "reported it",
    "involved" => "involved"
  }.freeze

  def slack_thread_url(channel_id, thread_ts)
    Fd::SlackLink.url_for(channel_id, thread_ts)
  end

  def role_label(role)
    ROLE_LABELS.fetch(role, role)
  end

  ROLE_TONES = {
    "involved" => "chip-warn",
    "reporter" => "chip-off",
    "subject" => "chip-crit"
  }.freeze

  def role_tone(role)
    ROLE_TONES.fetch(role, "chip-off")
  end

  def person_note(person, context)
    return person.detail if person.detail.present?
    return nil unless context&.known?

    subject_context_line(context)
  end

  def reply_latency_label(report)
    return "no reply yet" unless report.replied?

    case_age_label(report.reply_latency)
  end

  def reports_summary(reports)
    return "n/a" if reports.empty?

    anonymous = reports.count(&:anonymous?)
    parts = ["#{pluralize(reports.size, 'report')}"]
    parts << "#{anonymous} anonymous" if anonymous.positive?
    parts.join(" · ")
  end

  RESOLUTION_LABELS = {
    "action_taken" => "Action taken",
    "no_action" => "No action needed",
    "duplicate" => "Duplicate of another case",
    "not_conduct" => "Not a conduct matter",
  }.freeze

  def resolution_label(key)
    RESOLUTION_LABELS.fetch(key, key.to_s.tr("_", " "))
  end

  def resolution_options
    Fd::Case::RESOLUTIONS.map { |key| [resolution_label(key), key] }
  end

  def close_reason_options
    Fd::Case::CLOSE_REASONS.map { |key| [resolution_label(key), key] }
  end

  def action_options
    ACTION_LABELS.map { |key, label| [label, key] }
  end

  def category_label(key)
    return "n/a" if key.blank?

    Fd::Case.category_label(key)
  end

  def category_options
    Fd::Case::CATEGORIES.map { |key| [category_label(key), key] }
  end

  def span_label(seconds)
    return "n/a" if seconds.nil?

    days = seconds / 86_400.0
    return "#{days.round(1)}d" if days >= 1

    hours = seconds / 3600.0
    return "#{hours.round}h" if hours >= 1

    "#{(seconds / 60).round}m"
  end

  def median_note(stats)
    return "nothing resolved this quarter" if stats.median_now.nil?
    return "no quarter to compare with yet" if stats.median_before.nil?

    "was #{span_label(stats.median_before)} last quarter"
  end

  def oldest_unassigned_chip(stats)
    return tag.span("none waiting", class: "chip chip-off") if stats.oldest_unassigned.nil?

    age = Time.current - stats.oldest_unassigned
    tag.span("oldest #{case_age_label(age)}", class: "chip #{age_tone(age)}")
  end

  def since_label(at)
    at ? "since #{at.strftime('%b %Y')}" : "none yet"
  end

  def facet_link(query, key, value)
    fd_cases_path(query.facet_params(key => value))
  end

  def thread_kind_note(thread)
    return "internal discussion" if thread.internal?
    return "primary thread" if thread.is_primary

    "evidence, added later"
  end

  def note_byline(note)
    ["@#{note.author}", note.created_at.strftime("%b %-d, %Y")].join(" · ")
  end

  def notes_summary(notes, standing)
    return "nothing written down yet" if notes.empty? && standing.empty?

    parts = []
    parts << "#{notes.size} on this case" if notes.any?
    parts << "#{standing.size} standing on the member" if standing.any?
    parts.join(" · ")
  end

  def action_option_label(action)
    [
      action_label(action.type_key),
      "on @#{action.target_user_id}",
      action.performed_at.strftime("%b %-d, %Y"),
    ].join(" · ")
  end

  def action_options_for(actions)
    actions.map { |action| [action_option_label(action), action.id] }
  end

  def lone_subject(kase)
    ids = kase.subject_user_ids
    ids.first if ids.one?
  end

  def subject_handles(kase)
    ids = kase.subject_user_ids
    return "no subject set" if ids.empty?
    return "@#{ids.first}" if ids.one?

    "@#{ids.first} and #{pluralize(ids.size - 1, 'other')}"
  end

  def case_option_label(kase)
    parts = ["##{kase.id}"]
    parts << subject_handles(kase)
    parts << kase.category_key.tr("_", " ") if kase.category_key
    parts << case_age_label(case_age_seconds(kase))
    parts.join(" · ")
  end

  def case_options(cases)
    cases.map { |kase| [case_option_label(kase), kase.id] }
  end

  def case_status_chip(kase)
    if kase.resolved?
      tag.span(kase.resolution.tr("_", " "), class: "chip chip-off")
    else
      tag.span("open", class: "chip chip-crit")
    end
  end

  def filed_by_label(reports)
    return nil if reports.empty?

    named = reports.reject(&:anonymous?)

    if named.empty?
      reports.one? ? "filed anonymously" : "filed anonymously by #{reports.size} people"
    elsif reports.one?
      "filed by #{named.first.reporter_label}"
    else
      "filed by #{named.first.reporter_label} and #{pluralize(reports.size - 1, 'other')}"
    end
  end

  def case_head_meta(kase, reports)
    parts = []
    parts << kase.category_key.tr("_", " ") if kase.category_key
    opened = "opened #{kase.opened_at.strftime('%b %-d')}"

    if !kase.assigned?
      parts << "#{opened} by @#{kase.opened_by}"
      parts << "unassigned"
    elsif kase.assignee_user_ids == [kase.opened_by]
      parts << "#{opened} and assigned to @#{kase.opened_by}"
    else
      parts << "#{opened} by @#{kase.opened_by}"
      parts << "assigned to #{kase.assignee_handles}"
    end

    filed = filed_by_label(reports)
    parts << filed if filed
    parts.join(" · ")
  end

  ACTION_LABELS = {
    "warning" => "Warning",
    "shush" => "Shush",
    "temp_ban" => "Temporary ban",
    "indef_ban" => "Indefinite ban",
    "perma_ban" => "Permanent ban",
    "channel_ban" => "Channel ban",
    "locked_thread" => "Locked thread",
    "dm" => "DM"
  }.freeze

  def action_label(type_key)
    ACTION_LABELS.fetch(type_key) { type_key.tr("_", " ").capitalize }
  end

  def action_state_chip(action)
    return tag.span("reversed", class: "chip chip-off") if action.reversed?
    return tag.span("expired", class: "chip chip-off") if action.expired?

    if action.expires?
      remaining = case_age_label(action.expires_at - Time.current)
      return tag.span("expires in #{remaining}", class: "chip chip-warn")
    end

    nil
  end

  def action_performer_note(action)
    return "performed themselves" if action.performed_by_decider?

    "performed by @#{action.performed_by}"
  end

  def action_detail_note(action)
    channel = action.details["channel_id"]
    parts = []
    parts << channel if channel.present?
    parts << "via #{action.source_app}" if action.source_app != "fire_engine"
    parts.join(" · ").presence
  end

  def action_target_note(action, kase)
    return "the subject" if kase.subject_user_ids.include?(action.target_user_id)

    "not the subject"
  end

  def fact_number(value)
    value ? number_with_delimiter(value) : "n/a"
  end

  def last_active_label(at)
    return "n/a" if at.nil?

    days = (Date.current - at.to_date).to_i
    return "today" if days <= 0
    return "yesterday" if days == 1
    return "#{days}d ago" if days < 30

    at.to_date.strftime("%b %-d, %Y")
  end

  def claimed_phrase(context)
    return "claimed" if context.cohort_at.nil?

    if context.claimed_at.to_date == context.cohort_at.to_date
      "claimed the same day"
    else
      "claimed #{context.claimed_at.to_date.strftime('%b %-d, %Y')}"
    end
  end

  def subject_identity_line(user_id, context)
    return "nobody identified yet" if user_id.blank?

    parts = [user_id]
    if context&.known?
      parts << "joined #{context.cohort_at.to_date.strftime('%b %-d, %Y')}" if context.cohort_at
      parts << (context.claimed_at ? claimed_phrase(context) : "never claimed")
    else
      parts << "not in the warehouse yet"
    end
    parts.join(" · ")
  end

  def subject_context_line(context)
    return "nobody identified yet" if context.nil?
    return "not in the warehouse yet" unless context.known?

    parts = [tenure_label(context.tenure_days)]
    if context.messages_posted
      parts << "#{number_with_delimiter(context.messages_posted)} messages"
    end
    parts << "#{context.channels_joined} channels" if context.channels_joined
    parts.join(" · ")
  end

  def timeline_standing(kase, timeline)
    return "Nothing has happened on this case yet." if timeline.empty?

    if kase.resolved?
      "Resolved #{kase.resolved_at.strftime('%-d %b')} as #{kase.resolution.tr('_', ' ')}. " \
        "#{timeline.size} entries, kept whether or not Slack still has the thread."
    else
      assigned = kase.assigned? ? "assigned to #{kase.assignee_handles}" : "still unassigned"
      "Still open. #{case_age_label(case_age_seconds(kase))}, #{assigned}. " \
        "Nothing ages out: it stays here until somebody resolves it."
    end
  end
end
