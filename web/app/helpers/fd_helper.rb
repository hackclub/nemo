module FdHelper
  AGE_WARN = 2.days
  AGE_CRIT = 5.days

  def names
    @names || Fd::Names.none
  end

  def handle(user_id)
    return "n/a" if user_id.blank?

    tag.button(names[user_id], type: "button", class: "handle", title: "copy #{user_id}",
      data: { controller: "copy", copy_id_value: user_id, action: "click->copy#write" })
  end

  def handle_list(user_ids)
    return "n/a" if user_ids.blank?

    safe_join(user_ids.map { |id| handle(id) }, ", ")
  end

  SLACK_TEAM_URL = "https://hackclub.slack.com/team".freeze

  def slack_member_url(user_id)
    "#{SLACK_TEAM_URL}/#{user_id}"
  end

  def joined_line(context)
    return "not in the warehouse yet" if context.nil? || !context.known?
    return "joined #{context.cohort_at.to_date.strftime('%-d %b %Y')}" if context.claimed_at.nil?

    "joined #{context.cohort_at.to_date.strftime('%-d %b %Y')}, #{claimed_phrase(context)}"
  end

  def identity_line(identity)
    return locked_note("Nothing on file") if identity.nil?
    return locked_note("Identity purged") if identity.purged?
    return locked_note("Email not collected yet") if identity.email.blank?

    locked_note(identity.email)
  end

  def locked_note(text)
    tag.span(class: "locked") do
      concat tag.svg(width: 11, height: 11, viewBox: "0 0 24 24", fill: "none",
        stroke: "currentColor", "stroke-width": 2) {
        concat tag.rect(x: 4, y: 10, width: 16, height: 10, rx: 2)
        concat tag.path(d: "M8 10V7a4 4 0 0 1 8 0v3")
      }
      concat text
    end
  end

  def at_name(user_id)
    shown = names[user_id]
    shown.start_with?("@") ? shown : "@#{shown}"
  end

  def mentioned(text)
    return "" if text.blank?

    parts = Fd::Mentions.split(text).map do |piece|
      found = piece.match(Fd::Mentions::SLACK)
      next piece unless found

      link_to at_name(found[1]), fd_member_path(found[1]), class: "mention", title: found[1]
    end

    safe_join(parts)
  end

  def already_open_line(cases, preset)
    asked = Array(preset).map { |person| person[:id] }
    caught = (cases.flat_map(&:subject_user_ids) & asked).uniq
    who = caught.any? ? names.list(caught) : "that member"

    "#{who} already #{caught.many? ? 'have' : 'has'} an open case."
  end

  def share_of(part, whole)
    return "n/a" if whole.to_i.zero?

    "#{((part.to_f / whole) * 100).round(1)}% of the workspace"
  end

  def member_severity(row)
    return "sev-crit" if row.open_cases.positive?
    return "sev-warn" if row.priors >= 2

    "sev-calm"
  end

  def member_activity_line(context)
    return nil unless context&.known?

    parts = []
    parts << "#{number_with_delimiter(context.messages_posted)} messages" if
      context.messages_posted
    parts << "#{context.channels_joined} channels" if context.channels_joined
    parts.join(" · ").presence
  end

  def last_case_label(at)
    return "n/a" if at.nil?

    at = at.to_time
    days = (Date.current - at.to_date).to_i
    return "today" if days <= 0
    return "#{days}d ago" if days < 30

    at.strftime("%-d %b %Y")
  end

  def member_state_chips(row)
    chips = []
    chips << tag.span("open case", class: "chip chip-crit") if row.open_cases.positive?
    chips << tag.span(pluralize(row.notes, "note"), class: "chip chip-warn") if
      row.notes.positive?
    if chips.empty? && row.subject_of.zero? && row.logged_in.zero?
      chips << tag.span("nothing on record", class: "chip chip-good")
    end
    chips << tag.span("resolved", class: "chip chip-off") if chips.empty?
    safe_join(chips, " ")
  end

  HISTORY_TONES = {
    "open" => "chip-crit",
    "subject" => "chip-crit",
    "involved" => "chip-warn",
    "reporter" => "chip-off",
    "reversed" => "chip-warn",
    "undone" => "chip-good"
  }.freeze

  def history_chip_tone(chip)
    HISTORY_TONES.fetch(chip) { chip.start_with?("expires") ? "chip-warn" : "chip-off" }
  end

  HISTORY_EMPTY = {
    "subject" => "No case has ever been about them.",
    "logged" => "They have never been logged in somebody else's case.",
    "actions" => "Nothing has ever been done to them."
  }.freeze

  def history_empty_note(only)
    HISTORY_EMPTY.fetch(only, "Nothing on record.")
  end

  def shape_sub(record)
    return "one case" if record.spine.one?

    months = ((record.last_case_at - record.first_case_at) / 30.days).floor
    span = months.positive? ? pluralize(months, "month") : "under a month"
    "#{span}, #{pluralize(record.spine.size, 'case')}"
  end

  def action_tally(record)
    return pluralize(record.actions.size, "action") if record.reversed_actions.zero?

    "#{record.reversed_actions} of #{record.actions.size} actions undone"
  end

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
    [names[note.author], note.created_at.strftime("%b %-d, %Y")].join(" · ")
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
      "on #{names[action.target_user_id]}",
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
    return names[ids.first] if ids.one?

    "#{names[ids.first]} and #{pluralize(ids.size - 1, 'other')}"
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
      "filed by #{named.first.reporter_label(names)}"
    else
      "filed by #{named.first.reporter_label(names)} and #{pluralize(reports.size - 1, 'other')}"
    end
  end

  def case_head_meta(kase, reports)
    parts = []
    parts << kase.category_key.tr("_", " ") if kase.category_key
    opened = "opened #{kase.opened_at.strftime('%b %-d')}"

    if !kase.assigned?
      parts << "#{opened} by #{names[kase.opened_by]}"
      parts << "unassigned"
    elsif kase.assignee_user_ids == [kase.opened_by]
      parts << "#{opened} and assigned to #{names[kase.opened_by]}"
    else
      parts << "#{opened} by #{names[kase.opened_by]}"
      parts << "assigned to #{names.list(kase.assignee_user_ids)}"
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

    "performed by #{names[action.performed_by]}"
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

    parts = [user_id.to_s]
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
      assigned = if kase.assigned?
        "assigned to #{names.list(kase.assignee_user_ids)}"
      else
        "still unassigned"
      end
      "Still open. #{case_age_label(case_age_seconds(kase))}, #{assigned}. " \
        "Nothing ages out: it stays here until somebody resolves it."
    end
  end
end
