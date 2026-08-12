module FdHelper
  AGE_WARN = 2.days
  AGE_CRIT = 5.days

  FILTER_TITLES = {
    "open" => "Open cases",
    "mine" => "Cases you claimed",
    "all" => "Every case"
  }.freeze

  FILTER_ORDERING = {
    "open" => "oldest first",
    "mine" => "oldest first",
    "all" => "newest first"
  }.freeze

  FILTER_EMPTY = {
    "open" => "Nothing open right now.",
    "mine" => "You have not claimed any open cases.",
    "all" => "n/a"
  }.freeze

  def filter_title(filter)
    FILTER_TITLES.fetch(filter, "Cases")
  end

  def filter_ordering(filter)
    FILTER_ORDERING.fetch(filter, "oldest first")
  end

  def filter_empty_note(filter)
    FILTER_EMPTY.fetch(filter, "n/a")
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
    "target" => "on the receiving end",
    "reporter" => "reported it",
    "witness" => "was in the thread",
    "participant" => "was in the thread"
  }.freeze

  def slack_thread_url(channel_id, thread_ts)
    Fd::SlackLink.url_for(channel_id, thread_ts)
  end

  def role_label(role)
    ROLE_LABELS.fetch(role, role)
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

  CATEGORY_LABELS = {
    "nos" => "Misconduct not otherwise specified",
    "adult" => "Adult",
    "insulting" => "Insulting or demeaning remarks",
    "bullying" => "Bullying",
    "discrimination" => "Discrimination",
    "hateful" => "Hateful remarks",
    "harassment_identity" => "Systematic harassment, identity based",
    "harassment_general" => "Systematic harassment, general",
    "nsfw_mild" => "Mild or ambiguous NSFW",
    "nsfw_extreme" => "Clear and extreme NSFW",
    "advertising" => "Advertising or recruiting",
    "spam" => "Spam",
    "fraud_hcb" => "HCB fraud",
    "fraud_referral" => "Referral fraud",
    "fraud_ysws" => "YSWS fraud",
    "fraud_other" => "Other fraud",
    "ban_evasion" => "Slack ban evasion"
  }.freeze

  LEARNED_FROM_LABELS = {
    "saw_it" => "I saw it myself",
    "told_in_dm" => "Somebody told me in a DM",
    "off_slack" => "Raised at an event or on a call",
    "staff" => "Passed on by staff"
  }.freeze

  def category_label(key)
    return "n/a" if key.blank?

    CATEGORY_LABELS.fetch(key) { key.tr("_", " ") }
  end

  def category_options
    Fd::Case::CATEGORIES.map { |key| [category_label(key), key] }
  end

  def learned_from_label(key)
    LEARNED_FROM_LABELS[key]
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

  def case_option_label(kase)
    parts = ["##{kase.id}"]
    parts << (kase.subject_user_id ? "@#{kase.subject_user_id}" : "no subject")
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

    if !kase.claimed?
      parts << "#{opened} by @#{kase.opened_by}"
      parts << "unassigned"
    elsif kase.claimed_by == kase.opened_by
      parts << "#{opened} and assigned to @#{kase.claimed_by}"
    else
      parts << "#{opened} by @#{kase.opened_by}"
      parts << "assigned to @#{kase.claimed_by}"
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
    return "the subject" if action.target_user_id == kase.subject_user_id

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

  def subject_identity_line(kase, context)
    return "nobody identified yet" if kase.subject_user_id.blank?

    parts = [kase.subject_user_id]
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
      assigned = kase.claimed? ? "assigned to @#{kase.claimed_by}" : "still unassigned"
      "Still open. #{case_age_label(case_age_seconds(kase))}, #{assigned}. " \
        "Nothing ages out: it stays here until somebody resolves it."
    end
  end
end
