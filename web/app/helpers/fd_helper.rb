module FdHelper
  AGE_WARN = 2.days
  AGE_CRIT = 5.days

  def names
    @names || Fd::Names.none
  end

  def channels
    @channels || Fd::ChannelNames.none
  end

  def channel_label(channel_id)
    channels[channel_id]
  end

  def handle(user_id)
    return "n/a" if user_id.blank?

    tag.button(names[user_id], type: "button", class: "handle", title: "copy #{user_id}",
      data: { controller: "copy", copy_id_value: user_id, action: "click->copy#write" })
  end

  def member_link(user_id)
    return "n/a" if user_id.blank?

    link_to names[user_id], fd_member_path(user_id), class: "lnk", title: user_id,
      data: { turbo_frame: "person-drawer" }
  end

  def handle_list(user_ids)
    return "n/a" if user_ids.blank?

    safe_join(user_ids.map { |id| handle(id) }, ", ")
  end

  SLACK_TEAM_URL = "https://hackclub.slack.com/team".freeze

  def slack_member_url(user_id)
    "#{SLACK_TEAM_URL}/#{user_id}"
  end

  def claimed_phrase(context)
    return "claimed" if context.cohort_at.nil?

    if context.claimed_at.to_date == context.cohort_at.to_date
      "claimed the same day"
    else
      "claimed #{context.claimed_at.to_date.strftime('%b %-d, %Y')}"
    end
  end

  def joined_line(context)
    return "not in the warehouse yet" if context.nil? || !context.known?
    return "joined #{context.cohort_at.to_date.strftime('%-d %b %Y')}" if context.claimed_at.nil?

    "joined #{context.cohort_at.to_date.strftime('%-d %b %Y')}, #{claimed_phrase(context)}"
  end

  def identity_line(identity)
    return locked_note("Nothing on file") if identity.nil?
    return locked_note("Not yours to read") if identity.refused?
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
      said = piece.match(Fd::Mentions::SLACK)
      next mention_link(said[1]) if said

      room = piece.match(Fd::Mentions::CHANNEL)
      next channel_mention(room[1], room[2]) if room

      piece
    end

    safe_join(parts)
  end

  def mention_link(user_id)
    link_to at_name(user_id), fd_member_path(user_id), class: "mention", title: user_id
  end

  def channel_mention(channel_id, said = nil)
    named = channels.named?(channel_id) ? channel_label(channel_id) : nil
    shown = named || (said.present? ? "##{said}" : channel_id)
    link_to shown, channel_path(channel_id), class: "mention", title: channel_id
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

  def member_sort_header(label, key, numeric: false)
    css = ["th-sort"]
    css << "col-num" if numeric
    css << (@query.descending? ? "sort-down" : "sort-up") if @query.sorting?(key)

    tag.th(class: css.join(" "),
      aria: { sort: sort_state(key) }) do
      link_to fd_members_path(@query.sort_params(key)), data: { turbo_frame: "roster" } do
        concat tag.span(label)
        concat sort_caret(key)
      end
    end
  end

  def sort_state(key)
    return nil unless @query.sorting?(key)

    @query.descending? ? "descending" : "ascending"
  end

  def sort_caret(key)
    return tag.span("", class: "sort-mark") unless @query.sorting?(key)

    tag.span(@query.descending? ? "▾" : "▴", class: "sort-mark on", aria: { hidden: true })
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
    "standing" => "chip-warn",
    "action taken" => "chip-good",
    "resolved, no action" => "chip-good",
    "no action" => "chip-good",
    "reversed" => "chip-off",
    "logged in" => "chip-off"
  }.freeze

  def history_chip_tone(state)
    HISTORY_TONES.fetch(state.to_s, "chip-off")
  end

  HISTORY_EMPTY = {
    "cases" => "No case has ever involved them.",
    "actions" => "Nothing has ever been done to them.",
    "notes" => "Nobody has written a standing note about them."
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

  def member_facts(context, identity)
    parts = []
    parts << joined_line(context)
    parts << "here #{tenure_label(context.tenure_days)}" if context&.tenure_days
    parts << "active #{last_active_label(context.last_active_at)}" if context&.last_active_at
    if context&.messages_posted
      parts << "#{fact_number(context.messages_posted)} messages" \
               "#{" in #{context.channels_joined} channels" if context.channels_joined}"
    end
    safe_join(parts.compact.map { |part| tag.span(part) } + [identity_line(identity)], " ")
  end

  def member_standing_tone(standing)
    return "stand-clean" if standing.clean?
    return "stand-live" if standing.anything_in_force?

    "stand-quiet"
  end

  def member_standing_line(standing, names)
    return "Nothing on record, and nothing ever done to them." if standing.clean?

    safe_join([priors_phrase(standing), actions_phrase(standing),
               open_case_phrase(standing, names)].compact, " ")
  end

  def priors_phrase(standing)
    return "No priors in twelve months." if standing.priors.zero?

    tag.b("#{pluralize(standing.priors, 'prior')} in twelve months.")
  end

  def actions_phrase(standing)
    return nil if standing.actions.zero?

    parts = ["#{pluralize(standing.in_force.size, 'action')} still standing"]
    parts << "#{standing.reversed} reversed" if standing.reversed.positive?
    "#{parts.join(', ')}."
  end

  def open_case_phrase(standing, names)
    kase = standing.open_case
    return "No case is open on them." if kase.nil?

    holders = standing.holders
    with = if holders.empty?
      "with nobody"
    elsif holders.include?(current_staff&.user_id)
      "with you"
    else
      "with #{names.list(holders)}"
    end
    safe_join(["Case", link_to("##{kase.id}", fd_case_path(kase), class: "lnk"),
               "is open, #{with}."], " ")
  end

  BANS = %w[perma_ban indef_ban temp_ban channel_ban].freeze

  def standing_chip(standing)
    action = standing.worst
    return tag.span("nothing on record", class: "chip chip-good") if standing.clean?
    return tag.span("nothing standing", class: "chip chip-off") if action.nil?

    said = action_label(action.type_key).downcase
    said += action.expires? ? " until #{action.expires_at.strftime('%-d %b')}" : " in force"
    tone = BANS.include?(action.type_key) ? "chip-crit" : "chip-warn"
    tag.span(said, class: "chip #{tone}")
  end

  def subject_standing(user_id, context)
    parts = ["subject"]
    parts << tenure_label(context.tenure_days) if context&.tenure_days
    parts.join(" · ")
  end

  def person_line(person, context, said_counts, total_messages)
    parts = []
    parts << "here #{tenure_label(context.tenure_days)}" if context&.tenure_days
    parts << "active #{last_active_label(context.last_active_at)}" if context&.last_active_at
    parts << said_phrase(said_counts.fetch(person.user_id, 0), total_messages)
    parts += person.records.filter_map { |record| record.detail.presence }
    parts.compact.join(" · ").presence || person.user_id
  end

  def said_phrase(said, total)
    return nil if said.zero?
    return pluralize(said, "message") if said == total

    "said #{said} of the #{total} messages"
  end

  def prior_chip_for(count)
    tag.span(prior_phrase(count), class: "chip #{prior_tone(count)}")
  end

  def merge_reason(kase, other)
    shared = kase.threads.map(&:coordinates) & other.threads.map(&:coordinates)
    return "same thread in #{shared.first.first}" if shared.any?

    both = kase.subject_user_ids & other.subject_user_ids
    return "same subject" if both.any?

    "also open"
  end

  def resolve_consequences(kase, open_reports)
    lines = ["Case ##{kase.id} closes, and leaves the queue."]
    if open_reports.positive?
      lines << "#{pluralize(open_reports, 'reporter')} #{open_reports == 1 ? 'is' : 'are'} " \
               "told the outcome, unless you turn that off."
    end
    lines << "Filing a report logs an action against somebody, which counts as a prior."
    lines << "It is written to the trail either way, and can be reopened."
    lines
  end

  def action_consequences(kase, target)
    ["An action is logged against #{target ? names[target] : 'whoever you pick'}, " \
       "and counts as a prior for twelve months.",
     "Case ##{kase.id} stays #{kase.resolved? ? 'resolved' : 'open'}.",
     "Nobody is messaged. Telling them is a separate step.",
     "It is written to the trail, and can be reversed."]
  end

  def flagged_count(row, flags)
    row.messages.count { |said| flags.key?(said.id) }
  end

  def shown_messages(row, flags, only)
    return row.messages unless only == "flagged"

    row.messages.select { |said| flags.key?(said.id) }
  end

  def evidence_empty_note(row, only)
    return "Nothing in this thread is flagged." if only == "flagged"

    "No messages held for this thread yet."
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
    "subject" => "subject",
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

  ChatEntry = Struct.new(:at, :side, :kind, :who, :name, :body, :state, keyword_init: true)

  def chat_stream(kase)
    "case_#{kase.id}_chat"
  end

  def chat_log_id(kase)
    "chat-log-#{kase.id}"
  end

  def state_tone(state)
    return "chip-crit" if state.start_with?("undelivered")
    return "chip-warn" if state == "sending"

    "chip-off"
  end

  def chat_entries(reports, chat, messages = [], queued = [])
    said = messages.any? ? messages.map { |one| message_entry(one) } : opening(reports)
    said += reports.filter_map { |report| told_entry(report) }
    said += chat.map { |line| chat_entry(line) }
    said += queued.map { |row| queued_entry(row) }
    said.sort_by(&:at)
  end

  def opening(reports)
    reports.map do |report|
      ChatEntry.new(at: report.received_at, side: "in", kind: "them",
        who: (report.reporter_user_id unless report.anonymous?),
        name: report.reporter_label(names),
        body: report.body.presence || "No words with it.")
    end
  end

  def message_entry(said)
    theirs = said.theirs?
    ChatEntry.new(
      at: said.posted_at,
      side: theirs ? "in" : "out",
      kind: theirs ? "them" : "us",
      who: theirs ? said.author_user_id : said.sent_by,
      name: message_name(said),
      body: message_body(said),
      state: ("deleted in Slack" if said.deleted?)
    )
  end

  def message_name(said)
    return names[said.author_user_id] if said.theirs? && said.author_user_id
    return "them" if said.theirs?
    return names[said.sent_by] if said.sent_by

    "the Fire Department"
  end

  def message_body(said)
    said.body.presence || "no words, only what was attached"
  end

  def queued_entry(row)
    ChatEntry.new(at: row.requested_at, side: "out", kind: "us",
      who: row.requested_by, name: names[row.requested_by], body: row.body,
      state: row.failed? ? "undelivered, #{row.error}" : "sending, #{signing(row)}")
  end

  def signing(row)
    row.mode == "signed" ? "from #{names[row.requested_by]}" : "anonymous"
  end

  def told_entry(report)
    return nil unless report.told_of_outcome?

    ChatEntry.new(at: report.closed_at, side: "out", kind: "us",
      who: report.closed_by, name: names[report.closed_by],
      body: "Told them how it ended.")
  end

  def chat_entry(line)
    ChatEntry.new(at: line.said_at, side: "out", kind: "chat", who: line.author_user_id,
      name: names[line.author_user_id], body: chat_body(line))
  end

  def chat_body(line)
    return "#{line.body} (deleted in Slack)" if line.deleted?

    line.body
  end

  def reporter_names(reports)
    return "anonymous" if reports.all?(&:anonymous?)

    named = reports.reject(&:anonymous?).map { |report| names[report.reporter_user_id] }.uniq
    reports.any?(&:anonymous?) ? "#{named.to_sentence} and anonymous" : named.to_sentence
  end

  def merge_candidate_line(kase)
    held = if kase.assigned?
      "with #{names.list(kase.assignee_user_ids)}"
    elsif !kase.resolved?
      "nobody holding it"
    end
    ["opened #{kase.opened_at.strftime('%-d %b')}", held].compact.join(" · ")
  end

  def merge_hold_line(plan)
    "##{plan.keeper.id} will hold #{plan.pair? ? 'both' : "all #{plan.all.size}"}."
  end

  def merge_thread_line(plan)
    carried = plan.folded_cases.count { |one| one.reports.any? }
    return nil if carried.zero?

    if carried == 1
      "Its report thread comes across and keeps its own conversation."
    else
      "Their report threads come across and each keeps its own conversation."
    end
  end

  def merge_fold_line(plan)
    numbers = plan.folded_cases.map { |one| "##{one.id}" }.to_sentence
    closes = plan.folded_cases.one? ? "closes as a duplicate" : "close as duplicates"
    lands = plan.folded_cases.one? ? "its link lands" : "their links land"
    "#{numbers} #{closes}, and #{lands} on ##{plan.keeper.id}."
  end

  def merge_counts(plan)
    [
      pluralize(plan.reports, "report thread"),
      pluralize(plan.threads, "evidence thread"),
      pluralize(plan.actions, "action"),
      pluralize(plan.notes, "note"),
      pluralize(plan.people, "person", plural: "people")
    ].join(" · ")
  end

  def composer_hint(thread, names)
    return "Message the team" if thread.nil?

    "Message the team, or ? to reply to #{thread.reporter_label(names)}"
  end

  def chat_head_line(reports, kase)
    parts = []
    parts << "reported it #{report_when_short(reports.first)}"
    if reports.first.unanswered? && !kase.resolved?
      parts << "waiting #{case_age_label(reports.first.waiting_for)}"
    end
    parts.join(" · ")
  end

  def report_when_short(report)
    report.received_at.strftime("%-d %b")
  end

  def report_when_line(report, kase)
    parts = [report.received_at.strftime("%-d %b %Y, %H:%M")]
    parts << report.closed_line(names) if report.told_of_outcome?
    parts << "not told the outcome yet" if kase.resolved? && !report.told_of_outcome?
    parts.compact.join(" · ")
  end

  RESOLUTION_LABELS = Fd::Case::RESOLUTION_LABELS

  def told_chip(reports, open_reports)
    return nil if reports.blank?

    return tag.span(told_phrase(reports.size), class: "chip chip-good") if open_reports.zero?

    tag.span("#{pluralize(open_reports, 'reporter')} not told", class: "chip chip-warn")
  end

  def told_phrase(count)
    count == 1 ? "reporter was told" : "#{count} reporters were told"
  end

  def resolution_label(key)
    RESOLUTION_LABELS.fetch(key, key.to_s.tr("_", " "))
  end

  def closing_because(actions)
    said = actions.map { |action| action_label(action.type_key).downcase }.uniq.to_sentence
    "action taken, #{said}"
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
    return nil if stats.oldest_unassigned.nil?

    age = Time.current - stats.oldest_unassigned
    tag.span("oldest #{case_age_label(age)}", class: "chip #{age_tone(age)}")
  end

  def since_label(at)
    at ? "since #{at.strftime('%b %Y')}" : "none yet"
  end

  def facet_link(query, key, value)
    fd_cases_path(query.facet_params(key => value))
  end

  def note_byline(note)
    safe_join([member_link(note.author), note.created_at.strftime("%b %-d, %Y")], " · ")
  end

  def action_option_label(action)
    [
      action_label(action.type_key),
      "on #{names[action.target_user_id]}",
      action.performed_at.strftime("%b %-d, %Y")
    ].join(" · ")
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

  def category_short(key)
    return "n/a" if key.blank?

    key.tr("_", " ")
  end

  def row_subtitle(kase, thread_counts, thread_channels = {})
    parts = [category_short(kase.category_key), row_origin_phrase(kase)]
    parts << row_messages_phrase(kase, thread_counts, thread_channels)
    parts << row_merged_phrase(kase)
    safe_join(parts.compact.reject { |part| part == "n/a" }, " · ")
  end

  def row_merged_phrase(kase)
    return nil if kase.duplicate_of.blank?

    safe_join(["merged into ",
      link_to("##{kase.duplicate_of}", fd_case_path(kase.duplicate_of), class: "row-merged")])
  end

  def row_origin_phrase(kase)
    reports = kase.reports.to_a
    return "#{names[kase.opened_by]} opened it" if reports.empty?

    named = reports.reject(&:anonymous?)
    return "#{pluralize(reports.size, 'person')} reported it" if reports.many?
    return "a member reported it" if named.empty?

    "#{names[named.first.reporter_user_id]} reported it"
  end

  def row_messages_phrase(kase, thread_counts, thread_channels)
    count = thread_counts.fetch(kase.id, 0)
    return nil unless count.positive?

    said = pluralize(count, "message")
    where = Array(thread_channels[kase.id])
    return said unless where.one? && channels.named?(where.first)

    "#{said} in #{channels[where.first]}"
  end

  AVATAR_TONES = 8

  def avatar_tone(user_id)
    return "av-none" if user_id.blank?

    "av-#{(user_id.sum % AVATAR_TONES) + 1}"
  end

  def face(user_id, css: "row-avatar")
    letter = user_id ? names.initial(user_id) : "?"
    tag.span(letter, class: "#{css} #{avatar_tone(user_id)}", aria: { hidden: true })
  end

  def row_avatar(kase)
    id = kase.subject_user_ids.first if kase.subject_user_ids.one?
    face(id)
  end

  def assignee_faces(user_ids)
    return "n/a" if user_ids.blank?

    safe_join(Array(user_ids).map { |id|
      tag.span(class: "face-name") { safe_join([face(id), handle(id)]) }
    }, " ")
  end

  def row_subject_avatar(kase)
    face(kase.subject_user_ids.first)
  end

  def row_subject_label(kase)
    ids = kase.subject_user_ids
    return "nobody identified yet" if ids.empty?
    return names[ids.first] if ids.one?

    "#{names[ids.first]} and #{pluralize(ids.size - 1, 'other')}"
  end

  def row_reporter_id(kase)
    reports = kase.reports.to_a
    return kase.opened_by if reports.empty?

    reports.reject(&:anonymous?).first&.reporter_user_id
  end

  def row_reporter_avatar(kase)
    face(row_reporter_id(kase))
  end

  def row_reporter_label(kase)
    reports = kase.reports.to_a
    return names[kase.opened_by] if reports.empty?

    named = reports.reject(&:anonymous?)
    return "anonymous" if named.empty?
    return names[named.first.reporter_user_id] if reports.one?

    "#{names[named.first.reporter_user_id]} and #{pluralize(reports.size - 1, 'other')}"
  end

  PRIOR_TONES = { 0 => "chip-good", 1 => "chip-off" }.freeze

  def prior_phrase(count)
    case count
    when 0 then "never reported before"
    when 1 then "1 prior"
    else "#{count} priors"
    end
  end

  def prior_tone(count)
    PRIOR_TONES.fetch(count, "chip-crit")
  end

  def prior_chip(kase, prior_counts)
    return "n/a" unless kase.subject_user_ids.one?

    count = prior_counts.fetch(kase.subject_user_ids.first, 0)
    tag.span(prior_phrase(count), class: "chip #{prior_tone(count)}")
  end

  def case_option_label(kase)
    parts = ["##{kase.id}"]
    parts << subject_handles(kase)
    parts << category_short(kase.category_key) if kase.category_key
    parts << case_age_label(case_age_seconds(kase))
    parts.join(" · ")
  end

  def case_options(cases)
    cases.map { |kase| [case_option_label(kase), kase.id] }
  end

  CASE_TAB_LABELS = {
    "report" => "Report", "evidence" => "Evidence", "actions" => "Actions",
    "notes" => "Notes", "people" => "People"
  }.freeze

  def case_tab_groups(counts)
    tabs = Fd::CasesController::TABS.map { |key| { key: key, label: CASE_TAB_LABELS.fetch(key),
      count: counts[key] } }
    tabs.partition { |tab| tab[:key] == "report" || tab[:count].to_i.positive? }
  end

  def case_status_chip(kase)
    if kase.resolved?
      tag.span(kase.resolution.tr("_", " "), class: "chip chip-off")
    else
      tag.span("open", class: "chip chip-crit")
    end
  end

  def case_head_meta(kase, reports)
    parts = []
    parts << kase.category_key.tr("_", " ") if kase.category_key
    parts << case_origin_label(kase, reports)
    parts << if kase.assigned?
      safe_join(["assigned to ", member_links(kase.assignee_user_ids)])
    else
      "unassigned"
    end
    safe_join(parts, " · ")
  end

  def case_origin_label(kase, reports)
    first = Array(reports).min_by(&:received_at)
    return safe_join(["opened #{on_day(kase.opened_at)} by ",
      member_link(kase.opened_by)]) if first.nil?

    said = "reported #{on_day(first.received_at)}"
    return "#{said} by #{pluralize(reports.size, 'person')}" if reports.many?
    return "#{said} by a member" if first.anonymous?

    safe_join(["#{said} by ", member_link(first.reporter_user_id)])
  end

  def on_day(at)
    at.strftime("%b %-d")
  end

  def member_links(user_ids)
    return "n/a" if user_ids.blank?

    safe_join(Array(user_ids).map { |user_id| member_link(user_id) }, ", ")
  end

  ACTION_LABELS = Fd::Action::LABELS

  def action_label(type_key)
    ACTION_LABELS.fetch(type_key) { type_key.tr("_", " ").capitalize }
  end

  ACTION_TONES = {
    "warning" => "chip-warn", "shush" => "chip-warn", "locked_thread" => "chip-off",
    "dm" => "chip-off"
  }.freeze

  def action_tone(action)
    return "chip-off" if action.reversed?

    ACTION_TONES.fetch(action.type_key, "chip-crit")
  end

  def action_line(action, kase)
    aside = kase.subject_user_ids.include?(action.target_user_id) ? "" : " (not the subject)"
    safe_join([
      "to ", member_link(action.target_user_id),
      "#{aside}, #{action.performed_at.strftime('%-d %b')}, by ", member_link(action.decided_by)
    ])
  end

  def action_standing_line(action, kase)
    parts = []
    parts << reversal_line(action) if action.reversed?
    parts << "expires #{action.expires_at.strftime('%-d %b %Y')}" if action.expires?
    parts << action_detail_note(action)
    parts << action_performer_note(action) unless action.performed_by_decider?
    parts << "follows #{kase.followed_decision.title}" if kase.followed_decision
    parts.compact.join(" · ")
  end

  def reversal_line(action)
    why = action.reversal_reason.present? ? ", #{action.reversal_reason}" : ""
    "reversed #{action.reversed_at.strftime('%-d %b')} by #{names[action.reversed_by]}#{why}"
  end

  def action_labels(actions)
    actions.map { |action| action_label(action.type_key).downcase }.uniq.to_sentence
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

  def cite_options(messages)
    messages.map do |said|
      words = said.body.to_s.truncate(60)
      shown = "#{said.channel_id} #{said.posted_at.strftime('%-d %b %H:%M')} " \
        "#{names[said.author_user_id]}: #{words.presence || 'no text held'}"
      [shown, said.id]
    end
  end

  def cited_line(action)
    said = action.cited_message
    return nil if said.nil?

    "cites #{names[said.author_user_id]} in #{said.channel_id}, " \
      "#{said.posted_at.strftime('%-d %b %H:%M')}"
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

  def pane_identity_line(user_id, context)
    parts = [user_id.to_s]
    if context&.known?
      parts << "joined #{context.cohort_at.to_date.strftime('%b %Y')}" if context.cohort_at
      parts << member_activity_line(context)
      parts << "active #{last_active_label(context.last_active_at)}" if context.last_active_at
    else
      parts << "not in the warehouse yet"
    end
    parts.compact_blank.join(" · ")
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

  DECISION_CHIPS = {
    "settled" => ["chip-good", "in force"],
    "proposed" => ["chip-warn", "proposed"],
    "superseded" => ["chip-off", "retired"]
  }.freeze

  def decision_state_chip(decision)
    tone, label = DECISION_CHIPS.fetch(decision.state)
    tag.span(label, class: "chip #{tone}")
  end

  def decision_when_line(decision)
    case decision.state
    when "proposed"
      safe_join(["written #{decision.proposed_at.strftime('%-d %b')} by ",
        member_link(decision.proposed_by)])
    when "settled"
      safe_join(["settled #{decision.settled_at.strftime('%-d %b')} by ",
        member_link(decision.settled_by)])
    else
      retired = safe_join(["retired #{decision.retired_at.strftime('%-d %b')} by ",
        member_link(decision.retired_by)])
      return retired if decision.replacement.nil?

      safe_join([retired, "replaced by #{decision.replacement.title}"], " · ")
    end
  end

  def decision_thread_note(count)
    count.to_i.zero? ? "no threads" : pluralize(count, "thread")
  end

  def decision_row_line(decision, threads)
    safe_join([decision_when_line(decision), decision_thread_note(threads)], " · ")
  end

  ROLE_CHIPS = { "community_manager" => ["chip-crit", "manager"],
                 "lead" => ["chip-warn", "lead"],
                 "firefighter" => ["chip-off", "firefighter"] }.freeze

  def role_chip(role)
    tone, said = ROLE_CHIPS.fetch(role, ["chip-off", role])
    tag.span(said, class: "chip #{tone}")
  end

  def you_initial
    said = current_profile&.display_name.presence || current_staff.user_id
    said.strip.first.to_s.upcase
  end

  def slack_link_chip(held, gone = nil)
    return tag.span("stopped working", class: "chip chip-warn") if gone || held&.stumbled?
    return tag.span("not linked", class: "chip chip-off") if held.nil?

    tag.span("linked", class: "chip chip-good")
  end

  def role_tally(grants)
    counted = grants.group_by(&:role).transform_values(&:size)
    said = Fd::Permission::ROLES.reverse.filter_map do |role|
      next if counted[role].to_i.zero?

      "#{counted[role]} #{Fd::Permission::ROLE_LABELS.fetch(role).downcase.pluralize(counted[role])}"
    end
    said.any? ? "#{pluralize(grants.size, 'person')} · #{said.join(' · ')}" : "nobody yet"
  end

  def holds_mark(held)
    tag.span(held ? "yes" : "no", class: held ? "yes" : "no")
  end

  def role_switch(key, role)
    held = Fd::Permission.roles(key).include?(role)
    return holds_mark(held) if Fd::Permission.locked?(key) || !current_staff.may?("access.grant")

    button_to held ? "yes" : "no",
      fd_role_permission_path(role: role, key: key, allowed: held ? "0" : "1"),
      method: :patch, class: "switch #{held ? 'yes' : 'no'}",
      title: "#{held ? 'take' : 'give'} #{key} #{held ? 'from' : 'to'} " \
        "#{Fd::Permission::ROLE_LABELS.fetch(role).downcase}",
      form: { class: "contents" }
  end

  def moved_chip(key)
    return nil unless Fd::RolePermission.moved?(key)

    tag.span("moved", class: "chip chip-warn")
  end

  GIVEN_OUTSIDE = %w[manually backfill].freeze

  def given_by(user_id)
    GIVEN_OUTSIDE.include?(user_id) ? "manually" : names[user_id]
  end

  def acted_label(at)
    return "never" if at.nil?

    last_case_label(at)
  end

  DEED_WORDS = {
    "case/opened" => "Opened",
    "case/claimed" => "Claimed",
    "case/unclaimed" => "Handed back",
    "case/resolved" => "Resolved",
    "case/reopened" => "Reopened",
    "case/categorised" => "Set what kind of thing",
    "case/followed" => "Linked a decision to",
    "case/unfollowed" => "Unlinked a decision from",
    "note/noted" => "Wrote a note on",
    "note/deleted" => "Deleted a note on",
    "participant/attached" => "Added somebody to",
    "participant/detached" => "Took somebody off",
    "assignee/attached" => "Assigned",
    "assignee/detached" => "Unassigned",
    "assignee/claimed" => "Claimed",
    "assignee/unclaimed" => "Handed back",
    "thread/attached" => "Attached a thread to",
    "thread/detached" => "Detached a thread from",
    "citation/flagged" => "Flagged a message on",
    "citation/unflagged" => "Unflagged a message on",
    "action/performed" => "Logged an action on",
    "action/reversed" => "Reversed an action on",
    "report/received" => "Took a report on",
    "report/closed" => "Told the reporter on",
    "decision/proposed" => "Proposed",
    "decision/amended" => "Reworded",
    "decision/dropped" => "Dropped",
    "decision/settled" => "Settled",
    "decision/superseded" => "Retired",
    "decision_thread/attached" => "Linked a thread to",
    "decision_thread/detached" => "Unlinked a thread from",
    "grant/granted" => "Gave access to",
    "grant/revoked" => "Took access from",
    "permission/granted" => "Gave a role",
    "permission/revoked" => "Took from a role",
    "identity/read" => "Read the identity of",
    "slack_account/linked" => "Linked their Slack account",
    "slack_account/unlinked" => "Unlinked their Slack account"
  }.freeze

  def why_not(key, record = nil)
    Fd::Access.why_not(current_staff, key, record)
  end

  def opens_modal(key, text = nil, opens:, on: nil, css: "btn", &block)
    why = why_not(key, on)
    body = block ? capture(&block) : text
    return tag.label(body, for: opens, class: css) if why.nil?

    dead_button(body, why, css)
  end

  def gated_button(key, text, path, on: nil, css: "btn", **options)
    why = why_not(key, on)
    return dead_button(text, why, css) if why

    form = { class: "contents" }.merge(options.delete(:form) || {})
    button_to text, path, class: css, form: form, **options
  end

  def dead_button(text, why, css = "btn")
    tag.span(text, class: "#{css} btn-off", title: why, aria: { disabled: "true" })
  end

  def did_path(person, key, asked)
    fd_settings_path(tab: "usage", person: person.user_id, did: (key unless asked == key))
  end

  def tally_link(user_id, count, key = nil)
    return count.to_s if count.zero?

    link_to count, fd_settings_path(tab: "usage", person: user_id, did: key), class: "lnk"
  end

  def deed_words(event)
    DEED_WORDS.fetch(event) { event.tr("_/", " ").capitalize }
  end

  def deed_head(deed)
    return deed_words(deed.event) if deed.kind.nil?

    safe_join([deed_words(deed.event), deed_link(deed)], " ")
  end

  def deed_link(deed)
    case deed.kind
    when "case" then link_to deed.about, fd_case_path(deed.id), class: "lnk"
    when "decision" then link_to deed.about, fd_decision_path(deed.id), class: "lnk"
    else member_link(deed.id)
    end
  end

  def deed_said(deed)
    [deed.said, ("on #{names[deed.who]}" if deed.who.present?)].compact.join(" ")
  end

  def acted_line(at)
    at ? "acted #{last_case_label(at)}" : "nothing yet"
  end

  def grant_change_note(given, taken_back)
    return "no change in 30 days" if given.zero? && taken_back.zero?

    "#{given} given, #{taken_back} taken back"
  end

  def reads_note(counts, top)
    return "none in 30 days" if top.nil?

    said = pluralize(counts.size, "person")
    counts.one? ? said : "#{said}, most by #{names[top.first]}"
  end

  def refused_note(kinds)
    return "none in 30 days" if kinds.empty?

    kinds.map { |key, count| "#{count} #{key}" }.join(" · ")
  end

  def dormant_note(grants, shown)
    return "everyone has used theirs" if grants.empty?

    safe_join(grants.first(shown).map { |grant| dormant_chip(grant) }, " ")
  end

  def dormant_chip(grant)
    held = ((Time.current - grant.granted_at) / 1.day).floor
    tag.span("#{names[grant.user_id]}, #{tenure_label(held)}", class: "chip chip-warn")
  end

  def load_bar(share)
    tag.span(class: "bar#{' warm' if share.zero?}") do
      tag.i("", style: "width: #{[share, 100].min}%")
    end
  end

  def grant_span(grant)
    from = grant.granted_at.strftime("%-d %b %Y")
    grant.live? ? "since #{from}" : "#{from} to #{grant.revoked_at.strftime('%-d %b %Y')}"
  end

  def grant_state_chip(grant)
    return tag.span("live", class: "chip chip-good") if grant.live?

    tag.span("ended", class: "chip chip-off")
  end

  def followed_chip(kase)
    decision = kase.followed_decision
    return nil if decision.nil?

    tone = decision.proposed? ? "chip-warn" : "chip-crit"
    said = decision.proposed? ? "behind #{decision.title}" : "followed #{decision.title}"
    link_to said, fd_decision_path(decision), class: "chip #{tone}"
  end

  DECISION_GROUPS ={ "settled" => "In force", "proposed" => "Proposed",
                      "superseded" => "Retired" }.freeze
  DECISION_ORDER = { "settled" => 0, "proposed" => 1, "superseded" => 2 }.freeze

  def decision_groups(kase, decisions)
    decisions.group_by(&:state).sort_by { |state, _| DECISION_ORDER.fetch(state) }
      .map { |state, group| [DECISION_GROUPS.fetch(state), ordered_for(kase, group)] }
  end

  def ordered_for(kase, decisions)
    decisions.sort_by { |one| [one.category_key == kase.category_key ? 0 : 1, one.title] }
      .map { |one| [one.title, one.id] }
  end

  def cases_band_label(decision)
    decision.settled? ? "Cases that followed it" : "Cases behind it"
  end

  def decision_case_note(count)
    count.to_i.zero? ? "n/a" : pluralize(count, "case")
  end

  def decision_head_meta(decision)
    parts = []
    parts << decision.category_label.downcase if decision.category_key
    parts << decision_when_line(decision)
    safe_join(parts, " · ")
  end

  def decision_history_line(decision)
    parts = [safe_join(["proposed #{decision.proposed_at.strftime('%-d %b %Y')} by ",
      member_link(decision.proposed_by)])]

    if decision.settled_at
      parts << safe_join(["settled #{decision.settled_at.strftime('%-d %b %Y')} by ",
        member_link(decision.settled_by)])
    end

    if decision.retired_at
      parts << safe_join(["retired #{decision.retired_at.strftime('%-d %b %Y')} by ",
        member_link(decision.retired_by)])
    end

    if decision.replacement
      parts << safe_join(["replaced by ",
        link_to(decision.replacement.title, fd_decision_path(decision.replacement), class: "lnk")])
    end

    safe_join(parts, " · ")
  end

  def timeline_standing(kase, timeline)
    return "Nothing has happened on this case yet." if timeline.empty?

    if kase.resolved?
      "Resolved #{kase.resolved_at.strftime('%-d %b')} as #{kase.resolution.tr('_', ' ')}."
    else
      assigned = if kase.assigned?
        "assigned to #{names.list(kase.assignee_user_ids)}"
      else
        "still unassigned"
      end
      "Still open. #{case_age_label(case_age_seconds(kase))}, #{assigned}."
    end
  end
end
