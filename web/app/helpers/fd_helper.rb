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

  def channel_link(channel_id)
    return tag.span(channels[channel_id], class: "sub2") if channel_id.blank?

    link_to channels[channel_id], slack_channel_url(channel_id), class: "handle",
      title: channel_id, target: "_blank", rel: "noopener"
  end

  def handle(user_id)
    return "nobody" if user_id.blank?

    tag.button(names[user_id], type: "button", class: "handle", title: "copy #{user_id}",
      data: { controller: "copy", copy_id_value: user_id, action: "click->copy#write" })
  end

  def member_link(user_id)
    return "n/a" if user_id.blank?

    link_to names[user_id], fd_member_path(user_id), class: "lnk", title: user_id,
      data: { turbo_frame: "person-drawer" }
  end

  SLACK_TEAM_URL = "https://hackclub.slack.com/team".freeze

  def slack_member_url(user_id)
    "#{SLACK_TEAM_URL}/#{user_id}"
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

      wrapped = piece.match(Fd::Mentions::LINK)
      next linked(wrapped[1], wrapped[2]) if wrapped
      next linked(piece) if piece.match?(Fd::Mentions::BARE)

      piece
    end

    safe_join(parts)
  end

  def linked(url, label = nil)
    href = CGI.unescapeHTML(url.to_s)
    return href unless href.start_with?("http://", "https://")

    link_to link_label(href, label), href, class: "said-link",
      target: "_blank", rel: "noopener"
  end

  def link_label(href, label = nil)
    said = CGI.unescapeHTML(label.to_s)
    return said if said.present? && said != href

    ref = Fd::SlackLink.parse(href)
    return channel_label(ref.channel_id) if ref

    href.delete_prefix("https://").delete_prefix("http://").truncate(48)
  end

  def mention_link(user_id)
    link_to at_name(user_id), fd_member_path(user_id), class: "mention", title: user_id
  end

  def channel_mention(channel_id, said = nil)
    named = channels.named?(channel_id) ? channel_label(channel_id) : nil
    shown = named || (said.present? ? "##{said}" : channel_id)
    return tag.span(shown, class: "mention", title: channel_id) unless may_open_channel?(channel_id)

    link_to shown, channel_path(channel_id), class: "mention", title: channel_id
  end

  def may_open_channel?(channel_id)
    return false unless on?(:analytics)
    return true unless respond_to?(:current_account)

    @may_open ||= {}
    @may_open.fetch(channel_id) {
      @may_open[channel_id] = Channels::Audience.may_see?(current_account, channel_id)
    }
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

  def case_sort_header(label, key, numeric: false)
    css = ["th-sort"]
    css << "num" if numeric
    css << (@query.descending? ? "sort-down" : "sort-up") if @query.sorting?(key)

    tag.th(class: css.join(" "), aria: { sort: sort_state(key) }) do
      link_to fd_cases_path(@query.sort_params(key)), data: { turbo_frame: "queue" } do
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

  def on_day(at, none: "n/a")
    at ? at.to_time.strftime("%-d %b %Y") : none
  end

  def ago_label(at, none: "n/a")
    return none if at.nil?

    days = (Date.current - at.to_time.to_date).to_i
    return "today" if days <= 0
    return "yesterday" if days == 1
    return "#{days}d ago" if days < 30

    on_day(at)
  end

  def last_case_label(at)
    ago_label(at)
  end

  def member_standing_swatch(row)
    word, tone =
      if row.open_cases.positive? then ["open case", "state-warn"]
      elsif row.in_force.positive? then ["in force", "state-crit"]
      elsif row.notes.positive? || row.cases.positive? then ["noted", "state-warn"]
      else ["clean", "state-off"]
      end

    tag.span(word, class: "state #{tone}")
  end

  def member_state_chips(row)
    chips = []
    chips << tag.span("open case", class: "chip chip-crit") if row.open_cases.positive?
    chips << tag.span("#{row.in_force} in force", class: "chip chip-warn") if
      row.in_force.positive?
    if chips.empty? && row.subject_of.zero? && row.logged_in.zero?
      chips << tag.span("nothing on record", class: "chip chip-off")
    end
    chips << tag.span("resolved", class: "chip chip-off") if chips.empty?
    safe_join(chips, " ")
  end

  def wrong_on?(field)
    flash[:wrong].is_a?(Hash) && flash[:wrong]["field"] == field.to_s
  end

  def field_wrong(field)
    return nil unless wrong_on?(field)

    tag.p(flash[:wrong]["said"], class: "field-wrong")
  end

  def field_was(field, fallback = nil)
    wrong_on?(field) ? flash[:wrong]["was"] : fallback
  end

  def history_word_chip(entry)
    tone = case entry.word
    when "reversal" then "chip-good"
    when "action" then entry.state == "reversed" ? "chip-off" : "chip-warn"
    when "case" then ("chip-crit" if entry.state == "open")
    end
    tag.span(entry.word, class: ["chip", tone].compact.join(" "))
  end

  def member_tab_link(user_id, key, label, count)
    link_to fd_member_path(user_id, show: (key unless key == "all")),
      aria: { current: ("true" if key == @only) } do
      concat tag.span(label)
      concat tag.span(count, class: "seg-count")
    end
  end

  def menu_item(icon, label, note: nil)
    render "fd/menu_item", icon: icon, label: label, note: note
  end

  def history_by_month(entries)
    entries.group_by { |entry| entry.at.to_date.beginning_of_month }
  end

  def in_force_line(action, names)
    span = action.expires? ? " until #{on_day(action.expires_at)}" : ""
    tail = ", set by #{names[action.decided_by]} on #{on_day(action.performed_at)}"
    tail += " after case #{action.case_id}" if action.case_id
    safe_join([tag.b(action_label(action.type_key)), "#{span}#{tail}."])
  end

  HISTORY_EMPTY = {
    "cases" => "No case has ever involved them.",
    "actions" => "Nothing has ever been done to them.",
    "notes" => "Nobody has written a standing note about them."
  }.freeze

  def history_empty_note(only)
    HISTORY_EMPTY.fetch(only, "Nothing on record.")
  end

  def case_age_seconds(kase)
    (kase.resolved_at || Time.current) - kase.opened_at
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

  BANS = %w[perma_ban indef_ban temp_ban channel_ban].freeze

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

  PEOPLE_ORDER = %w[subject involved reporter].freeze

  def role_rank(role)
    PEOPLE_ORDER.index(role) || PEOPLE_ORDER.size
  end

  def main_role(person)
    PEOPLE_ORDER.find { |role| person.roles.include?(role) } || person.role
  end

  def people_in_order(people)
    people.sort_by { |person| role_rank(main_role(person)) }
  end

  def person_roles_line(person)
    person.roles.sort_by { |role| role_rank(role) }
      .map { |role| role_label(role) }.join(" · ")
  end

  def people_head_line(people)
    return "Nobody on this case" if people.size.zero?

    "#{pluralize(people.size, "person")} on this case"
  end

  REMOVE_LABELS = {
    "subject" => "Remove as the subject",
    "involved" => "Remove as involved",
    "reporter" => "Remove as a reporter"
  }.freeze

  def remove_person_label(person, record)
    return "Take them off the case" if person.records.one?

    REMOVE_LABELS.fetch(record.role, "Remove as #{record.role}")
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

  def citation_numbers(flags)
    flags.keys.each_with_index.to_h { |id, i| [id, "E#{i + 1}"] }
  end

  def messages_by_day(messages)
    messages.group_by { |said| said.posted_at.to_date }
  end

  def age_ink(seconds)
    return "age-crit" if seconds >= AGE_CRIT
    return "age-warn" if seconds >= AGE_WARN

    ""
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

  ChatEntry = Struct.new(:key, :at, :side, :kind, :who, :name, :body, :state, keyword_init: true)

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
    said = messages.any? ? [] : opening(reports)
    said += reports.filter_map { |report| told_entry(report) }
    (said + changed_chat_entries(reports, chat, messages, queued)).sort_by(&:at)
  end

  def changed_chat_entries(reports, chat, messages, queued)
    hidden = reports.any?(&:anonymous?)
    said = messages.map { |one| message_entry(one, hidden) }
    said += chat.map { |line| chat_entry(line) }
    said += queued.map { |row| queued_entry(row) }
    said.sort_by(&:at)
  end

  def opening(reports)
    reports.map do |report|
      ChatEntry.new(key: "open-#{report.id}", at: report.received_at, side: "in", kind: "them",
        who: (report.reporter_user_id unless report.anonymous?),
        name: report.reporter_label(names),
        body: report.body.presence || "No words with it.")
    end
  end

  def message_entry(said, hidden = false)
    theirs = said.theirs?
    masked = theirs && hidden
    ChatEntry.new(
      key: "msg-#{said.id}",
      at: said.posted_at,
      side: theirs ? "in" : "out",
      kind: theirs ? "them" : "us",
      who: masked ? nil : (theirs ? said.author_user_id : said.sent_by),
      name: message_name(said, hidden),
      body: message_body(said),
      state: ("deleted in Slack" if said.deleted?)
    )
  end

  def message_name(said, hidden = false)
    return "anonymous" if said.theirs? && hidden
    return names[said.author_user_id] if said.theirs? && said.author_user_id
    return "them" if said.theirs?
    return names[said.sent_by] if said.sent_by

    "the Fire Department"
  end

  def message_body(said)
    said.body.presence || "no words, only what was attached"
  end

  def queued_entry(row)
    ChatEntry.new(key: "queued-#{row.id}", at: row.requested_at, side: "out", kind: "us",
      who: row.requested_by, name: names[row.requested_by], body: row.body,
      state: row.failed? ? "undelivered, #{row.error}" : "sending, #{signing(row)}")
  end

  def signing(row)
    row.mode == "signed" ? "from #{names[row.requested_by]}" : "anonymous"
  end

  def told_entry(report)
    return nil unless report.told_of_outcome?

    ChatEntry.new(key: "told-#{report.id}", at: report.closed_at, side: "out", kind: "us",
      who: report.closed_by, name: names[report.closed_by],
      body: "Told them how it ended.")
  end

  def chat_entry(line)
    ChatEntry.new(key: "chat-#{line.id}", at: line.said_at, side: "out", kind: "chat",
      who: line.author_user_id, name: names[line.author_user_id], body: chat_body(line))
  end

  def chat_body(line)
    return "#{line.body} (deleted in Slack)" if line.deleted?

    line.body
  end

  def merge_candidate_line(kase)
    held = if kase.assigned?
      "with #{names.list(kase.assignee_user_ids)}"
    elsif !kase.resolved?
      "nobody holding it"
    end
    ["opened #{on_day(kase.opened_at)}", held].compact.join(" · ")
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

  def chat_head_line(reports, kase, said: 0)
    parts = []
    parts << "reported it #{report_when_short(reports.first)}"
    parts << pluralize(said, "message") if said.positive?
    if reports.first.unanswered? && !kase.resolved?
      parts << "waiting #{case_age_label(reports.first.waiting_for)}"
    end
    parts.join(" · ")
  end

  def report_when_short(report)
    on_day(report.received_at)
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

  def facet_link(query, key, value)
    fd_cases_path(query.facet_params(key => value))
  end

  def note_byline(note)
    safe_join([member_link(note.author), on_day(note.created_at)], " · ")
  end

  def action_option_label(action)
    [
      action_label(action.type_key),
      "on #{names[action.target_user_id]}",
      on_day(action.performed_at)
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

  def slack_face(user_id, css: "row-avatar")
    return face(user_id, css: css) if user_id.blank?

    link_to slack_member_url(user_id), class: "face-link", target: "_blank",
      rel: "noopener", title: "#{names[user_id]} in Slack" do
      face(user_id, css: css)
    end
  end

  def face(user_id, css: "row-avatar")
    shown = user_id.present? ? names.image(user_id) : nil
    return tag.img(src: shown, class: css, alt: "", loading: "lazy") if shown

    letter = user_id ? names.initial(user_id) : "?"
    tag.span(letter, class: "#{css} #{avatar_tone(user_id)}", aria: { hidden: true })
  end

  def row_avatar(kase)
    id = kase.subject_user_ids.first if kase.subject_user_ids.one?
    face(id)
  end

  def assignee_faces(user_ids)
    return "nobody" if user_ids.blank?

    safe_join(Array(user_ids).map { |id|
      tag.span(class: "face-name") { safe_join([slack_face(id), handle(id)]) }
    }, " ")
  end

  def row_subject_avatar(kase)
    face(kase.subject_user_ids.first)
  end

  def case_first_report(kase)
    kase.reports.min_by(&:received_at)
  end

  def case_excerpt(kase)
    case_first_report(kase)&.body.presence
  end

  def case_gist(kase)
    body = case_first_report(kase)&.body.presence
    return nil if body.nil?

    tag.span(class: "gist") { tag.q(body) }
  end

  def case_needs(kase)
    return [] if kase.resolved?

    return [] if kase.subject_user_ids.any?

    ["a subject"]
  end

  def case_reports_shown(kase)
    kase.reports.sort_by(&:received_at)
  end

  def report_reply_state(report)
    return [:told, report.closed_line(names)] if report.told_of_outcome?
    return [:replied, "replied #{on_day(report.first_replied_at)}"] if report.replied?

    [:waiting, "no reply to the reporter yet, #{case_age_label(report.waiting_for)}"]
  end

  def case_opened_by_line(kase)
    safe_join(["opened by ", member_link(kase.opened_by), " on #{on_day(kase.opened_at)}"])
  end

  def to_sentence_words(words)
    return words.first if words.one?

    "#{words[0..-2].join(', ')} and #{words.last}"
  end

  def row_reporter(kase)
    reports = kase.reports.to_a
    return kase.opened_by if reports.empty?

    reports.reject(&:anonymous?).first&.reporter_user_id
  end

  def row_reporter_face(kase)
    face(row_reporter(kase))
  end

  def case_priors(kase, counts)
    counts[kase.subject_user_id].to_i
  end

  def case_reporter_line(kase)
    first = case_first_report(kase)
    return "nobody" if first.nil?

    label = first.anonymous? ? "Anonymous" : names[first.reporter_user_id]
    extra = kase.reports.size - 1
    return label unless extra.positive?

    safe_join([label, tag.span("and #{extra} more", class: "card-thin")], " ")
  end

  def case_opened_line(kase, thread_channels)
    channel = Array(thread_channels[kase.id]).first
    parts = [on_day(kase.opened_at)]
    parts << channel_label(channel) if channel.present? && channels.named?(channel)
    parts.join(" · ")
  end

  def case_meta_line(kase, thread_channels)
    parts = []
    first = case_first_report(kase)
    parts << if first.nil?
      "opened by hand"
    else
      safe_join(["reported by ", case_reporter_line(kase)])
    end

    channel = Array(thread_channels[kase.id]).first
    where = channels.named?(channel) ? " in #{channel_label(channel)}" : ""
    parts << "#{on_day(kase.opened_at)}#{where}"

    parts << if kase.assigned?
      safe_join(["held by ", safe_join(kase.assignee_user_ids.map { |id| handle(id) }, ", ")])
    else
      "unclaimed"
    end

    if kase.resolved? && kase.category_key.present?
      parts << tag.b(category_label(kase.category_key))
    end

    safe_join(parts, " · ")
  end

  def case_standing_label(kase, prior_counts)
    return "Resolved" if kase.resolved?
    return "Needs a subject" if kase.subject_user_ids.empty?
    return "Held by #{kase.assignee_handles}" if kase.assigned?

    lone = kase.subject_user_ids.one? ? kase.subject_user_ids.first : nil
    return "#{kase.subject_user_ids.size} subjects" if lone.nil?

    prior_phrase(prior_counts.fetch(lone, 0))
  end

  def row_subject_label(kase)
    ids = kase.subject_user_ids
    return "nobody identified yet" if ids.empty?
    return names[ids.first] if ids.one?

    "#{names[ids.first]} and #{pluralize(ids.size - 1, 'other')}"
  end

  def row_reporter_label(kase)
    who = row_reporter(kase)
    return "anonymous" if who.blank?

    others = kase.reports.size - 1
    return names[who] if others < 1

    "#{names[who]} and #{pluralize(others, 'other')}"
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

  CASE_TAB_LABELS = {
    "report" => "Report", "evidence" => "Evidence", "actions" => "Actions",
    "notes" => "Notes", "people" => "People"
  }.freeze

  STILL_NEEDED = { 1 => "One thing", 2 => "Two things", 3 => "Three things" }.freeze

  def still_needed(missing)
    return if missing.empty?

    "#{STILL_NEEDED.fetch(missing.size, "#{missing.size} things")} before this can close"
  end

  def case_tabs(counts)
    Fd::CasesController::TABS.map { |key| { key: key, label: CASE_TAB_LABELS.fetch(key),
      count: counts[key] } }
  end

  def case_status_chip(kase)
    return tag.span(kase.resolution.tr("_", " "), class: "state state-off") if kase.resolved?

    tag.span("open", class: "state state-crit")
  end

  def case_head_meta(kase, reports)
    case_origin_label(kase, reports)
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


  ACTION_LABELS = Fd::Action::LABELS

  def action_label(type_key)
    ACTION_LABELS.fetch(type_key) { type_key.tr("_", " ").capitalize }
  end

  def action_standing_line(action, kase)
    parts = []
    parts << reversal_line(action) if action.reversed?
    parts << "via #{action.source_app}" if action.source_app != "fire_engine"
    parts << action_performer_note(action) unless action.performed_by_decider?
    parts << "follows #{kase.followed_decision.title}" if kase.followed_decision
    parts.compact.join(" · ").presence
  end

  def reversal_line(action)
    why = action.reversal_reason.present? ? ", #{action.reversal_reason}" : ""
    "reversed #{on_day(action.reversed_at)} by #{names[action.reversed_by]}#{why}"
  end

  def action_state_chip(action)
    return tag.span("reversed", class: "chip chip-off") if action.reversed?
    return tag.span("expired #{on_day(action.expires_at)}", class: "chip chip-off") if action.expired?

    return nil unless action.expires?

    remaining = case_age_label(action.expires_at - Time.current)
    tag.span("in force, #{remaining} left", class: "chip chip-warn")
  end

  def action_rail_tone(action)
    action.active? ? "sev-warn" : "sev-calm"
  end

  def actions_head_line(actions)
    standing = actions.count(&:active?)
    tail = standing.zero? ? "none still standing" : "#{standing} still standing"
    "#{pluralize(actions.size, "action")} · #{tail}"
  end

  def action_sentence(action)
    channel = action.details["channel_id"]
    parts = ["On ", member_link(action.target_user_id)]
    parts << " in #{channel_label(channel)}" if channel.present?
    parts << ", until #{on_day(action.expires_at)}" if action.expires?
    parts << ". Set by "
    parts << member_link(action.decided_by)
    parts << " on #{on_day(action.performed_at)}."
    safe_join(parts)
  end

  def violations_label(keys, short: false)
    return nil if keys.empty?

    keys.map { |key| short ? category_short(key) : category_label(key) }.join(", ")
  end

  def action_reason(action)
    said = action.reason.presence
    return tag.span("no reason recorded", class: "why-none") if said.nil?

    tag.q(said, class: "why-said")
  end

  def off_subject_chip(action, kase)
    return if kase.subject_user_ids.include?(action.target_user_id)

    tag.span("not the subject", class: "chip chip-crit")
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

  def fact_number(value)
    value ? number_with_delimiter(value) : "n/a"
  end

  def here_since(context)
    at = context&.cohort_at
    return "n/a" if at.nil?

    "#{at.to_date.strftime('%b %Y')} &middot; #{tenure_label(context.tenure_days)}".html_safe
  end

  def last_active_label(at)
    ago_label(at)
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

  def holds_mark(held)
    tag.span(held ? "yes" : "no", class: held ? "yes" : "no")
  end

  def flag_switch(key)
    showing = Fd::Flag.on?(key)
    return holds_mark(showing) unless current_account.may?("app.flip")

    button_to showing ? "yes" : "no",
      fd_flag_path(key: key, on: showing ? "0" : "1"),
      method: :patch, class: "switch #{showing ? 'yes' : 'no'}",
      title: "#{showing ? 'turn off' : 'turn on'} #{Fd::Flag.label(key).downcase}",
      form: { class: "contents" }
  end

  def moved_chip(key)
    return nil unless Authz::Override.moved?(key)

    tag.span("moved", class: "chip chip-warn")
  end

  GIVEN_OUTSIDE = %w[manually backfill].freeze

  def given_by(user_id)
    GIVEN_OUTSIDE.include?(user_id) ? "manually" : names[user_id]
  end

  def acted_label(at)
    ago_label(at, none: "never")
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
    Fd::Access.why_not(current_account, key, record)
  end

  def opens_modal(key, text = nil, opens:, on: nil, css: "btn", &block)
    why = why_not(key, on)
    body = block ? capture(&block) : text
    if why.nil?
      return tag.label(body, for: opens, class: css, tabindex: "0", role: "button")
    end

    dead_button(body, why, css)
  end

  def gated_button(key, text, path, on: nil, css: "btn", **options)
    why = why_not(key, on)
    return dead_button(text, why, css) if why

    form = { class: "contents" }.merge(options.delete(:form) || {})
    button_to text, path, class: css, form: form, **options
  end

  def dead_button(text, why, css = "btn")
    tag.span(class: "#{css} btn-off", title: why, aria: { disabled: "true" }) do
      concat tag.span(text)
      concat tag.span(why, class: "btn-why")
    end
  end

  def did_path(person, key, asked)
    admin_person_path(person.user_id)
  end

  def tally_link(user_id, count, key = nil)
    return count.to_s if count.zero?

    link_to count, admin_person_path(user_id), class: "lnk"
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
    grant.live? ? "since #{from}" : "#{from} to #{on_day(grant.revoked_at)}"
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
      "Resolved #{on_day(kase.resolved_at)} as #{kase.resolution.tr('_', ' ')}."
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
