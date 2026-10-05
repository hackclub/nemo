module FdHelper
  AGE_WARN = 2.days
  AGE_CRIT = 5.days

  def names
    @names || Fd::Names.none
  end

  def channels
    @channels || Fd::ChannelNames.none
  end

  def chat_emoji
    @emoji || {}
  end

  def channel_label(channel_id)
    channels[channel_id]
  end

  def channel_link(channel_id, permalink: nil)
    return tag.span(channels[channel_id], class: "sub2") if channel_id.blank?

    if permalink.present?
      return link_to(channels[channel_id], permalink, class: "handle",
        title: "open the message in Slack", target: "_blank", rel: "noopener")
    end

    link_to channels[channel_id], slack_channel_url(channel_id), class: "handle",
      title: channel_id, target: "_blank", rel: "noopener"
  end

  def handle(user_id)
    return "nobody" if user_id.blank?

    tag.button(person_name(user_id), type: "button", class: "handle", title: "copy #{user_id}",
      data: { controller: "copy", copy_id_value: user_id, action: "click->copy#write" })
  end

  def member_link(user_id)
    return "n/a" if user_id.blank?

    link_to person_name(user_id), fd_member_path(user_id), class: "lnk", title: user_id,
      data: { turbo_frame: "person-drawer" }
  end

  SLACK_TEAM_URL = "https://hackclub.slack.com/team".freeze

  def slack_member_url(user_id)
    "#{SLACK_TEAM_URL}/#{user_id}"
  end

  CF_EMAIL_OFF = "<!--email_off-->".html_safe
  CF_EMAIL_ON = "<!--/email_off-->".html_safe

  def plain_email(address, css: "mono")
    return nil if address.blank?

    safe_join([CF_EMAIL_OFF, tag.span(address, class: css), CF_EMAIL_ON])
  end

  def identity_line(identity)
    return locked_note("Nothing on file") if identity.nil?
    return locked_note("Not yours to read") if identity.refused?
    return locked_note("Identity purged") if identity.purged?
    return locked_note("Email not collected yet") if identity.email.blank?

    tag.span(class: "locked") { plain_email(identity.email, css: nil) }
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
      match = piece.match(Fd::Mentions::SLACK)
      next mention_link(match[1]) if match

      room = piece.match(Fd::Mentions::CHANNEL)
      next channel_mention(room[1], room[2]) if room

      wrapped = piece.match(Fd::Mentions::LINK)
      next linked(wrapped[1], wrapped[2]) if wrapped
      next linked(piece) if piece.match?(Fd::Mentions::BARE)

      piece
    end

    safe_join(parts)
  end

  def body_html(entry)
    blocks_html(entry.blocks.presence || Slack::Mrkdwn.blocks(entry.body))
  end

  def blocks_html(blocks)
    Slack::RichText.for({ "blocks" => blocks }, names: names, channels: channels,
      emoji: chat_emoji,
      user_chip: ->(id) { mention_link(id) }, channel_chip: ->(id) { channel_mention(id) },
      link_chip: ->(url, label) { linked(url, label) })
  end

  def linked(url, label = nil)
    href = CGI.unescapeHTML(url.to_s)
    return href unless href.start_with?("http://", "https://")

    link_to link_label(href, label), href, class: "link-note",
      target: "_blank", rel: "noopener"
  end

  def link_label(href, label = nil)
    text = CGI.unescapeHTML(label.to_s)
    return text if text.present? && text != href

    ref = Fd::SlackLink.parse(href)
    return channel_label(ref.channel_id) if ref

    href.delete_prefix("https://").delete_prefix("http://").truncate(48)
  end

  def mention_link(user_id)
    link_to at_name(user_id), fd_member_path(user_id), class: "mention", title: user_id,
      data: { turbo_frame: "person-drawer" }
  end

  PRIVATE_CHANNEL_LABEL = "#private-channel".freeze

  def channel_mention(channel_id, name = nil)
    return private_channel_chip(channel_id) if channels.private_unnamed?(channel_id)

    named = channels.named?(channel_id) ? channel_label(channel_id) : nil
    shown = named || (name.present? ? "##{name}" : channel_id)
    return tag.span(shown, class: "mention", title: channel_id) unless may_open_channel?(channel_id)

    link_to shown, fd_channel_path(channel_id), class: "mention", title: channel_id,
      data: { turbo_frame: "_top" }
  end

  def private_channel_chip(channel_id)
    tag.span(PRIVATE_CHANNEL_LABEL, class: "mention mention-private", title: channel_id)
  end

  def may_open_channel?(channel_id)
    return false unless on?(:analytics)
    return true unless respond_to?(:current_account)

    @may_open ||= {}
    @may_open.fetch(channel_id) {
      @may_open[channel_id] = Channels::Audience.may_see?(current_account, channel_id)
    }
  end

  def share_of(part, whole)
    return "n/a" if whole.to_i.zero?

    "#{((part.to_f / whole) * 100).round(1)}% of the workspace"
  end

  AUDIT_SOURCE = { "fire_engine" => "Fire Engine", "slack" => "Slack",
                   "read" => "Fire Engine", "api" => "Public API" }.freeze

  def audit_raw(row)
    JSON.pretty_generate(row.raw || row.detail || {})
  end

  def audit_verb(row)
    row.verb.to_s.tr("_", " ")
  end

  def audit_actor(row)
    return member_link(row.actor_id) if row.actor_id.present?
    return tag.span("nemo", class: "state") if row.actor_kind.to_s == "bot"

    tag.span("nobody named", class: "state")
  end

  AUDIT_CHANNEL = /\A[CGD][A-Z0-9]{2,}\z/
  AUDIT_MEMBER = /\A[UW][A-Z0-9]{2,}\z/

  def audit_about(row)
    return member_link(row.subject_id) if row.subject_id.present?

    refs = [row.entity_ref, row.entity_id].compact_blank
    room = refs.find { |one| one.match?(AUDIT_CHANNEL) }
    return audit_channel(room) if room

    who = refs.find { |one| one.match?(AUDIT_MEMBER) }
    return member_link(who) if who
    return tag.span("#{row.entity_kind} #{row.entity_id}", class: "sub2") if row.entity_id.present?

    tag.span(row.entity_kind.to_s.tr("_", " "), class: "sub2")
  end

  PRIVATE_CHANNEL = "#private-channel".freeze

  def audit_channel(channel_id)
    return tag.span(PRIVATE_CHANNEL, class: "sub2", title: channel_id) unless
      channels.named?(channel_id)

    link_to channel_label(channel_id), channel_path(channel_id), class: "lnk",
      title: channel_id
  end

  def audit_where(row)
    parts = [tag.span(AUDIT_SOURCE.fetch(row.source, row.source), class: "state")]
    parts << tag.span(row.ip, class: "mono audit-ip") if row.ip.present?
    parts << tag.span(row.app_name, class: "sub2") if row.app_name.present?
    safe_join(parts, " ")
  end

  AUDIT_VALUE = 80

  def audit_value(value)
    return tag.span("nothing", class: "sub2") if value.nil? || value == ""

    text = value.is_a?(String) ? value : value.to_json
    tag.span(text.truncate(AUDIT_VALUE), class: "mono")
  end

  DOMAIN_MATCH_LABELS = { "exact" => "exact", "suffix" => "with subdomains" }.freeze
  DOMAIN_EFFECT_LABELS = { "flag" => "write it down", "hold" => "shush them",
                           "deactivate" => "deactivate them" }.freeze
  DOMAIN_EFFECT_TONES = { "flag" => "", "hold" => "state-warn",
                          "deactivate" => "state-crit" }.freeze
  SCREEN_TONES = { "flagged" => "state-warn", "held" => "state-warn",
                   "deactivated" => "state-crit", "failed" => "state-crit" }.freeze

  def domain_match_label(key) = DOMAIN_MATCH_LABELS.fetch(key, key)

  def domain_effect_label(key) = DOMAIN_EFFECT_LABELS.fetch(key, key)

  def domain_match_chip(one)
    tag.span(domain_match_label(one.match_mode), class: "state")
  end

  def domain_effect_chip(one)
    tag.span(domain_effect_label(one.effect),
      class: "state #{DOMAIN_EFFECT_TONES.fetch(one.effect, '')}".strip)
  end

  def screen_outcome_chip(screen)
    tag.span(screen.outcome.tr("_", " "),
      class: "state #{SCREEN_TONES.fetch(screen.outcome, '')}".strip)
  end

  def link_band_chip(side)
    tone = { "certain" => "state-crit", "strong" => "state-warn" }.fetch(side.band, "")
    tag.span(side.band, class: "state #{tone}".strip)
  end

  def link_score_chip(score)
    score = score.to_f
    tone = if score >= Fd::MemberLink::CERTAIN
      "state-crit"
    elsif score >= Fd::MemberLink::STRONG
      "state-warn"
    else
      ""
    end
    tag.span(number_with_precision(score, precision: 1), class: "state #{tone}".strip)
  end

  def session_span(first_at, last_at)
    return "n/a" if first_at.nil? || last_at.nil?
    return on_day(last_at) if first_at.to_date == last_at.to_date

    "#{first_at.strftime('%-d %b')} \u2013 #{on_day(last_at)}"
  end

  def session_swatch(address)
    return tag.span("shared", class: "state state-crit") if address.alongside.any?
    return tag.span("crowded", class: "state") if address.crowded?
    return tag.span("shared", class: "state state-warn") if address.shared?

    tag.span("theirs alone", class: "state state-good")
  end

  def joiner_country(row)
    return tag.span("n/a", class: "sub2") if row.seen_country.blank?

    safe_join([
      (tag.span(row.flag, class: "joiner-flag") if row.flag),
      tag.span(Fd::Countries.name_for(row.seen_country))
    ].compact, " ")
  end

  def joiner_ip(row)
    return tag.span("never signed in", class: "sub2") if row.ip.blank?

    safe_join([
      tag.span(row.ip, class: "mono"),
      (if row.crowded?
         tag.span("#{row.seen_people} here", class: "state state-warn")
       elsif row.close_company?
         tag.span("#{row.seen_people} here", class: "state")
       end)
    ].compact, " ")
  end

  def joiner_sort_header(label, key, numeric: false)
    css = ["th-sort"]
    css << "col-num" if numeric
    css << (@query.descending? ? "sort-down" : "sort-up") if @query.sorting?(key)

    tag.th(class: css.join(" "), aria: { sort: sort_state(key) }) do
      link_to fd_joiners_path(@query.sort_params(key)) do
        concat tag.span(label)
        concat sort_caret(key)
      end
    end
  end

  JOINER_SOURCE = { "by_hand" => "written down by hand",
                    "cohort" => "from the cohort table" }.freeze

  def joiner_when(row)
    [row.joined_at.strftime("%-d %b %Y"), JOINER_SOURCE[row.source]].compact.join(" · ")
  end

  def joiner_standing(row)
    return tag.span("deactivated", class: "state state-crit") if row.deactivated?
    return tag.span("clear", class: "state") unless row.guarded?

    safe_join(Fd::MemberGuard.worst_kinds_first(row.kinds).map { |kind|
      tag.span(action_label(kind).downcase, class: "state state-warn")
    }, " ")
  end

  def member_sort_header(label, key, numeric: false)
    css = ["th-sort"]
    css << "col-num" if numeric
    css << (@query.descending? ? "sort-down" : "sort-up") if @query.sorting?(key)

    tag.th(class: css.join(" "),
      aria: { sort: sort_state(key) }) do
      path_params = @query.sort_params(key)
      path_params = path_params.merge(layout: params[:layout]) if params[:layout].present?
      link_to fd_members_path(path_params), data: { turbo_frame: "roster" } do
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
    flash[:field_error].is_a?(Hash) && flash[:field_error]["field"] == field.to_s
  end

  def field_wrong(field)
    return nil unless wrong_on?(field)

    tag.p(flash[:field_error]["message"], class: "field-wrong")
  end

  def field_was(field, fallback = nil)
    wrong_on?(field) ? flash[:field_error]["was"] : fallback
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
    link_to fd_member_path(user_id, (@pane_params || {}).merge(show: (key unless key == "all")).compact),
      class: "view", aria: { current: ("true" if key == @only) } do
      concat tag.span(label)
      concat tag.span(count, class: "tab-count")
    end
  end

  def menu_item(icon, label, note: nil)
    render "fd/menu_item", icon: icon, label: label, note: note
  end

  Stop = Struct.new(:key, :label, :icon, :path, :here, :tally, keyword_init: true)

  NAV_HOME = { "fd/fire" => "overview", "fd/members" => "members",
               "fd/joiners" => "joiners", "fd/member_links" => "links",
               "fd/channels" => "channels", "fd/audits" => "audit",
               "fd/configuration" => "configuration",
               "fd/channel_purges" => "channels" }.freeze

  def fd_nav_here
    NAV_HOME.fetch(controller_path, "cases")
  end

  def fd_nav_stops
    fd_nav_mark([
      Stop.new(key: "overview", label: "Overview", icon: "overview", path: fd_root_path),
      Stop.new(key: "cases", label: "Cases", icon: "shield", path: fd_cases_path,
        tally: Fd::Case.unresolved.not_duplicate.unassigned.count),
      Stop.new(key: "members", label: "Members", icon: "people", path: fd_members_path),
      Stop.new(key: "channels", label: "Channels", icon: "channels", path: fd_channels_path),
      Stop.new(key: "joiners", label: "Joiners", icon: "newcomers", path: fd_joiners_path)
    ])
  end

  def fd_nav_tools
    stops = []
    if current_account&.may?("app.configure")
      stops << Stop.new(key: "configuration", label: "Configuration", icon: "gear",
        path: fd_configuration_path)
    end
    if current_account&.may?("member.links")
      stops << Stop.new(key: "links", label: "Linked accounts", icon: "people",
        path: fd_links_path)
    end
    if current_account&.may?("access.read")
      stops << Stop.new(key: "audit", label: "Audit log", icon: "history", path: fd_audit_path)
    end
    fd_nav_mark(stops)
  end

  def fd_nav_mark(stops)
    here = fd_nav_here
    stops.each { |stop| stop.here = stop.key == here }
  end

  def case_action_button(icon, label, shortcut: nil)
    render "fd/case_action_button", icon: icon, label: label, shortcut: shortcut
  end

  def case_action_icon(icon)
    render "fd/case_action_button", icon: icon, label: nil, shortcut: nil
  end

  def history_by_month(entries)
    entries.group_by { |entry| entry.at.to_date.beginning_of_month }
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

    parts = [pluralize(standing.actions, "action")]
    parts << "#{standing.in_force.size} in force" if standing.in_force.any?
    parts << "#{standing.reversed} reversed" if standing.reversed.positive?
    "#{parts.join(', ')}."
  end

  BANS = %w[perma_ban indef_ban temp_ban channel_ban].freeze

  def subject_standing(user_id, context)
    parts = ["subject"]
    parts << tenure_label(context.tenure_days) if context&.tenure_days
    parts.join(" · ")
  end

  def person_line(person, context, priors)
    parts = []
    parts << "here #{tenure_label(context.tenure_days)}" if context&.tenure_days
    parts << "active #{last_active_label(context.last_active_at)}" if context&.last_active_at
    parts << prior_phrase(priors.fetch(person.user_id, 0))
    parts.compact.join(" · ").presence || person.user_id
  end

  PEOPLE_ORDER = %w[subject reporter].freeze

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
    "reporter" => "Remove as a reporter"
  }.freeze

  def remove_person_label(person, record)
    return "Take them off the case" if person.records.one?

    REMOVE_LABELS.fetch(record.role, "Remove as #{record.role}")
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
    "reporter" => "reported it"
  }.freeze

  def slack_thread_url(channel_id, thread_ts)
    Fd::SlackLink.url_for(channel_id, thread_ts)
  end

  def role_label(role)
    ROLE_LABELS.fetch(role, role)
  end

  ROLE_TONES = {
    "reporter" => "chip-off",
    "subject" => "chip-crit"
  }.freeze

  def role_tone(role)
    ROLE_TONES.fetch(role, "chip-off")
  end

  ChatEntry = Struct.new(:key, :at, :side, :kind, :who, :anon, :name, :body, :blocks, :state,
    :files, :shares, keyword_init: true)

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
    entries = messages.any? ? [] : opening(reports)
    (entries + changed_chat_entries(reports, chat, messages, queued)).sort_by(&:at)
  end

  GROUPED_WITHIN = 5.minutes

  def grouped_with?(entry, previous)
    return false if previous.nil?

    entry.kind == previous.kind && entry.who == previous.who &&
      (entry.at - previous.at) <= GROUPED_WITHIN
  end

  def changed_chat_entries(reports, chat, messages, queued)
    hidden = reports.any?(&:anonymous?)
    held = Fd::IntakeFile.for_messages(messages.map(&:id))
    cited = Fd::IntakeShare.for_messages(messages.map(&:id))
    entries = messages.map do |one|
      message_entry(one, hidden, held.fetch(one.id, []), cited.fetch(one.id, []))
    end
    entries += chat.map { |line| chat_entry(line) }
    entries += queued.map { |row| queued_entry(row) }
    entries.sort_by(&:at)
  end

  def opening(reports)
    reports.map do |report|
      ChatEntry.new(key: "open-#{report.id}", at: report.received_at, side: "in", kind: "them",
        who: (report.reporter_user_id unless report.anonymous?),
        anon: report.anonymous?,
        name: report.reporter_label(names),
        body: report.body.presence)
    end
  end

  def message_entry(message, hidden = false, files = [], shares = [])
    theirs = message.theirs?
    masked = theirs && hidden
    ChatEntry.new(
      key: "msg-#{message.id}",
      at: message.posted_at,
      side: theirs ? "in" : "out",
      kind: theirs ? "them" : "us",
      who: masked ? nil : (theirs ? message.author_user_id : message.sent_by),
      anon: masked,
      name: message_name(message, hidden),
      body: message_body(message, files),
      blocks: message.blocks,
      state: ("deleted in Slack" if message.deleted?),
      files: files,
      shares: shares
    )
  end

  def message_name(message, hidden = false)
    return "Anonymous" if message.theirs? && hidden
    return names[message.author_user_id] if message.theirs? && message.author_user_id
    return "them" if message.theirs?
    return names[message.sent_by] if message.sent_by

    "the Fire Department"
  end

  def message_body(message, _files = [])
    message.body.presence
  end

  def queued_entry(row)
    ChatEntry.new(key: "queued-#{row.id}", at: row.requested_at, side: "out", kind: "us",
      who: row.requested_by, name: names[row.requested_by], body: row.body,
      state: row.failed? ? "undelivered, #{row.error}" : "sending, #{signing(row)}",
      files: Fd::OutgoingFile.queued_on(row))
  end

  def signing(row)
    row.mode == "signed" ? "from #{names[row.requested_by]}" : "anonymous"
  end

  def chat_entry(line)
    ChatEntry.new(key: "chat-#{line.id}", at: line.posted_at, side: "out", kind: "chat",
      who: line.author_user_id, name: names[line.author_user_id], body: chat_body(line),
      blocks: (line.blocks unless line.deleted?))
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

  def chat_head_line(reports, kase, count: 0)
    parts = []
    parts << "reported it #{report_when_short(reports.first)}"
    parts << pluralize(count, "message") if count.positive?
    if reports.first.unanswered? && !kase.resolved?
      parts << "waiting #{case_age_label(reports.first.waiting_for)}"
    end
    parts.join(" · ")
  end

  def report_when_short(report)
    on_day(report.received_at)
  end

  RESOLUTION_LABELS = Fd::Case::RESOLUTION_LABELS

  def reports_chip(reports, open_reports)
    return nil if reports.blank?

    return tag.span(reports_phrase(reports.size), class: "chip chip-good") if open_reports.zero?

    tag.span("#{pluralize(open_reports, 'reporter')} not told", class: "chip chip-warn")
  end

  def reports_phrase(count)
    count == 1 ? "reporter was told" : "#{count} reporters were told"
  end

  def resolution_label(key)
    RESOLUTION_LABELS.fetch(key, key.to_s.tr("_", " "))
  end

  def closing_because(actions)
    labels = actions.map { |action| action_label(action.type_key).downcase }.uniq.to_sentence
    "action taken, #{labels}"
  end

  def close_reason_options
    Fd::Case::CLOSE_REASONS.map { |key| [resolution_label(key), key] }
  end

  def action_options
    ACTION_LABELS.map do |key, label|
      [label, key, { data: {
        expires: Fd::Action::NEEDS_EXPIRY.include?(key),
        channel: Fd::Action::TAKES_CHANNEL.include?(key),
        lock: Fd::Action.from_thread_lock?(key)
      } }]
    end
  end

  CONFIGURATION_TAB_LABELS = { "automod" => "Automod", "domains" => "Domains",
                              "responses" => "Responses" }.freeze

  def configuration_tab_label(key)
    CONFIGURATION_TAB_LABELS.fetch(key) { key.tr("_", " ").capitalize }
  end

  AUTOMOD_MODE_LABELS = {
    "word" => "Whole word",
    "substring" => "Substring",
    "regex" => "Regex"
  }.freeze

  def automod_mode_options
    Fd::AutomodWord::MATCHES.map { |key| [AUTOMOD_MODE_LABELS.fetch(key), key] }
  end

  def automod_mode_chip(word)
    tag.span(AUTOMOD_MODE_LABELS.fetch(word.match_mode, word.match_mode), class: "chip")
  end

  def category_label(key)
    return "n/a" if key.blank?

    Fd::Case.category_label(key)
  end

  def category_options
    Fd::Case::CATEGORIES.map { |key| [category_label(key), key] }
  end

  def note_byline(note)
    safe_join([member_link(note.author), on_day(note.created_at)], " · ")
  end

  def action_option_label(action)
    parts = [action_label(action.type_key)]
    parts << "on #{names[action.target_user_id]}" if action.aimed_at_member?
    parts << on_day(action.performed_at)
    parts.join(" · ")
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

    text = pluralize(count, "message")
    where = Array(thread_channels[kase.id])
    return text unless where.one? && channels.named?(where.first)

    "#{text} in #{channels[where.first]}"
  end

  AVATAR_TONES = 8

  def avatar_tone(user_id)
    return "avatar-none" if user_id.blank?

    "avatar-#{(user_id.sum % AVATAR_TONES) + 1}"
  end

  SUBJECTS_SHOWN = 3

  def subject_faces(kase)
    ids = kase.subject_user_ids
    return nil if ids.empty?

    shown = ids.first(SUBJECTS_SHOWN)
    parts = shown.map { |id|
      tag.span(class: "face-name", title: names[id]) {
        safe_join([slack_face(id), tag.span(member_link(id), class: "face-sub")])
      }
    }
    parts << tag.span("+#{ids.size - shown.size}", class: "face-more") if ids.size > shown.size
    tag.span(class: ["subjfaces", ("subjfaces-many" if ids.many?)]) { safe_join(parts) }
  end

  def preset_faces(user_ids)
    ids = Array(user_ids).compact.reject(&:blank?).uniq
    return [] if ids.empty?

    known = Fd::Names.for(ids)
    ids.map { |id| { id: id, name: known[id], initial: known.member(id)&.initial || id[0] } }
  end

  def slack_face(user_id, css: "row-avatar")
    return face(user_id, css: css) if user_id.blank?

    link_to slack_member_url(user_id), class: "face-link", target: "_blank",
      rel: "noopener", title: "#{names[user_id]} in Slack" do
      face(user_id, css: css)
    end
  end

  def face(user_id, css: "row-avatar", data: {})
    if user_id.blank?
      return tag.span("", class: "#{css} avatar-none", aria: { hidden: true }, data: data)
    end

    tag.img(src: cachet_face_url(user_id), class: css, alt: "", loading: "lazy",
      width: 22, height: 22,
      data: data.merge(cachet_face: user_id, cachet_initial: names.initial(user_id),
        cachet_tone: avatar_tone(user_id)))
  end

  def person_name(user_id)
    name = names[user_id]
    return name unless names.unknown?(user_id)

    tag.span(name, data: { cachet_name: user_id })
  end

  def case_first_report(kase)
    kase.reports.min_by(&:received_at)
  end

  def cited_words
    @cited_words || {}
  end

  A_LINK = %r{<https?://[^\s<>|]+(?:\|[^>]*)?>|https?://\S+}

  def only_a_link?(text)
    text = text.to_s
    !text.empty? && text.gsub(A_LINK, " ").blank?
  end

  def plain_text(text)
    text.to_s
      .gsub(/<(https?:\/\/[^\s<>|]+)\|([^>]*)>/) { Regexp.last_match(2) }
      .gsub(/<(https?:\/\/[^\s<>]+)>/) { Regexp.last_match(1) }
      .squish
  end

  def case_cited(kase)
    cited = cited_words[kase.id]
    return nil if cited.nil? || cited.body.blank?

    body = case_first_report(kase)&.body.presence
    return nil if body.present? && !only_a_link?(body)

    cited
  end

  def held_counts
    @held_counts || {}
  end

  def case_words(kase)
    body = case_first_report(kase)&.body.presence
    return plain_text(body) if body
    return "no report on file" if kase.reports.empty?

    held = held_counts[kase.id].to_i
    return pluralize(held, "attachment") if held.positive?

    "a report with nothing in it"
  end

  def row_reporter(kase)
    reports = kase.reports.to_a
    return kase.opened_by if reports.empty?

    reports.reject(&:anonymous?).first&.reporter_user_id
  end

  ANONYMOUS_FACE = "/anonymous.png".freeze

  def anonymous_face(css: "row-avatar")
    image_tag(ANONYMOUS_FACE, class: css, alt: "", width: 22, height: 22,
      loading: "lazy", title: "Anonymous")
  end

  def row_reporter_face(kase)
    who = row_reporter(kase)
    return face(who) if who.present?

    anonymous_face
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

  def row_reporter_label(kase)
    who = row_reporter(kase)
    return "Anonymous" if who.blank?

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
    "report" => "Report", "people" => "People",
    "actions" => "Actions", "notes" => "Notes", "timeline" => "Timeline"
  }.freeze

  TIMELINE_TONES = {
    "report" => "crit", "action" => "act", "resolve" => "good", "close" => "good",
    "claim" => "", "note" => "", "thread" => "", "person" => "", "open" => "", "reply" => ""
  }.freeze

  TIMELINE_GLYPHS = {
    "report" => "R", "action" => "A", "resolve" => "C", "close" => "C",
    "claim" => "@", "note" => "N", "thread" => "T", "person" => "P",
    "open" => "+", "reply" => "@"
  }.freeze

  def timeline_tone(mark)
    TIMELINE_TONES.fetch(mark.to_s, "")
  end

  def timeline_glyph(mark)
    tag.span(TIMELINE_GLYPHS.fetch(mark.to_s, "\u00b7"), class: "mono", style: "font-size:10px")
  end

  def case_tabs(counts)
    Fd::CasesController::TABS.map { |key| { key: key, label: CASE_TAB_LABELS.fetch(key),
      count: counts[key] } }
  end

  def case_status_chip(kase)
    return tag.span(kase.resolution.tr("_", " "), class: "state state-off") if kase.resolved?

    tag.span("open", class: "state state-crit")
  end

  def case_state_chip(kase, acted: nil, reachable: nil)
    label, tone = case_state(kase, acted: acted, reachable: reachable)
    tag.span(label, class: "state #{tone}")
  end

  def case_state(kase, acted: nil, reachable: nil)
    return ["folded into #{kase.duplicate_of}", "state-off"] if kase.duplicate_of
    return ["closed as #{kase.resolution.to_s.tr('_', ' ')}", "state-off"] if kase.resolved?

    reports = kase.reports.to_a
    reachable ||= reachable_reports(reports)
    unanswered = reports.any? do |one|
      reachable.include?(one.id) && !one.replied? && !one.told_of_outcome?
    end
    return ["no reply yet", "state-crit"] if unanswered
    return ["nobody on it", "state-warn"] unless kase.assigned?
    return ["needs a subject", "state-warn"] if kase.subject_user_ids.empty?

    taken = acted || kase.actions.reject(&:reversed?).size
    return ["acted, not closed", "state-live"] if taken.positive?
    return ["waiting on the reporter", "state"] if reports.any?(&:replied?)

    ["working", "state-live"]
  end

  def reachable_reports(reports)
    ids = reports.map(&:id)
    return Set.new if ids.empty?

    Fd::IntakeConversation.open_ones.where(report_id: ids).pluck(:report_id).to_set
  end

  def case_head_meta(kase, reports)
    case_origin_label(kase, reports)
  end

  def case_origin_label(kase, reports)
    first = Array(reports).min_by(&:received_at)
    return safe_join(["opened #{on_day(kase.opened_at)} by ",
      member_link(kase.opened_by)]) if first.nil?

    text = "reported #{on_day(first.received_at)}"
    return "#{text} by #{pluralize(reports.size, 'person')}" if reports.many?
    return "#{text} by a member" if first.anonymous?

    safe_join(["#{text} by ", member_link(first.reporter_user_id)])
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
    parts.compact.join(" · ").presence
  end

  def reversal_line(action)
    why = action.reversal_reason.present? ? ", #{action.reversal_reason}" : ""
    "reversed #{on_day(action.reversed_at)} by #{names[action.reversed_by]}#{why}"
  end

  def action_thread_url(action)
    return nil unless action.from_thread_lock?

    channel = action.details["channel_id"]
    thread = action.details["thread_ts"]
    return nil if channel.blank? || thread.blank?

    slack_thread_url(channel, thread)
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
    reversed = actions.count(&:reversed?)
    in_force = actions.count(&:in_force?)
    parts = [pluralize(actions.size, "action")]
    parts << "#{in_force} in force" if in_force.positive?
    parts << "#{reversed} reversed" if reversed.positive?
    parts.join(" · ")
  end

  def action_sentence(action)
    channel = action.details["channel_id"]
    parts = action.aimed_at_member? ? ["On ", member_link(action.target_user_id)] : ["On a thread"]
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
    reason = action.reason.presence
    return tag.span("no reason recorded", class: "why-none") if reason.nil?

    tag.q(reason, class: "why-quote")
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

  def fact_number(value)
    value ? number_with_delimiter(value) : "not tracked"
  end

  def member_since(context)
    at = context&.cohort_at
    return "n/a" if at.nil?

    "#{at.to_date.strftime('%b %Y')} &middot; #{tenure_label(context.tenure_days)}".html_safe
  end

  def last_active_label(at)
    ago_label(at)
  end

  ROLE_CHIPS = { "community_manager" => ["chip-crit", "manager"],
                 "lead" => ["chip-warn", "lead"],
                 "firefighter" => ["chip-off", "firefighter"] }.freeze

  def role_chip(role)
    tone, label = ROLE_CHIPS.fetch(role, ["chip-off", role])
    tag.span(label, class: "chip #{tone}")
  end

  def flag_switch(key)
    showing = Fd::Flag.on?(key)
    return nil unless current_account.may?("app.flip")

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
    "member/looked_up" => "Looked up",
    "report/received" => "Took a report on",
    "report/closed" => "Told the reporter on",
    "consent/granted" => "Opted in to",
    "consent/withheld" => "Opted out of",
    "api/checked" => "Checked",
    "api/setting_changed" => "Changed the",
    "api/token_minted" => "Generated a token,",
    "api/token_rate_set" => "Set the rate on",
    "api/token_revoked" => "Revoked a token,",
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

  def opens_modal(key, text = nil, opens:, on: nil, css: "btn", data: {}, &block)
    why = why_not(key, on)
    body = block ? capture(&block) : text
    if why.nil?
      return tag.button(body, type: "button", class: css,
        data: data.merge(modal_open: opens),
        aria: { haspopup: "dialog" })
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
    tag.span(class: "#{css} btn-off", tabindex: "0",
      aria: { disabled: "true", description: why }) do
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

  def audit_summary(event)
    DEED_WORDS.fetch(event) { event.tr("_/", " ").capitalize }
  end

  def audit_title(row)
    return audit_summary(row.event) if row.kind.nil?

    safe_join([audit_summary(row.event), audit_link(row)], " ")
  end

  def audit_link(row)
    case row.kind
    when "case" then link_to row.about, fd_case_path(row.id), class: "lnk"
    when "capability" then row.about
    else member_link(row.id)
    end
  end

  def audit_detail(row)
    [row.detail, ("on #{names[row.who]}" if row.who.present?)].compact.join(" ")
  end

  DIAL_LABELS = {
    "rate_per_minute" => "Requests a minute, per key",
    "batch_max" => "People per batch call",
    "tokens_per_owner" => "Live keys per app"
  }.freeze

  def token_life_line(token)
    return "never expires" if token.expires_at.nil?

    "expires #{token.expires_at.strftime('%-d %b %Y')}"
  end

  def dial_label(key)
    DIAL_LABELS.fetch(key, key.tr("_", " "))
  end

  ACCESS_CHIPS = { "approved" => "chip-good", "declined" => "chip-crit",
                   "withdrawn" => "chip-off", "pending" => "chip-warn" }.freeze

  def access_state_chip(state)
    tag.span(state, class: "chip #{ACCESS_CHIPS.fetch(state, 'chip-off')}")
  end

  def api_state_chip
    on = Fd::Flag.on?(:public_api)
    tag.span(class: "chip #{on ? 'chip-good' : 'chip-off'}") do
      tag.span(class: "chip-dot", aria: { hidden: true }) + (on ? "On" : "Off")
    end
  end

  def withheld_share(withheld, checks)
    return "none yet" if checks.zero?

    "#{(withheld * 100.0 / checks).round(1)}% of checks"
  end

  def synced_line(at)
    return "never" if at.nil?

    swept = Api::ChannelSweep.count
    "#{at.strftime('%-d %b %H:%M')}, #{swept} #{'channel'.pluralize(swept)}"
  end

  def dial_reach(key, tokens)
    live = tokens.reject(&:revoked?)
    return "#{live.count { |one| one.rate_limit.nil? }} of #{live.size}" if key == "rate_per_minute"

    "every caller"
  end

  def dial_change(setting)
    return "never" if setting.nil? || setting.changed_by.blank?

    "#{names[setting.changed_by]}, #{setting.changed_at.strftime('%-d %b')}"
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

  def timeline_standing(kase, timeline)
    return "Nothing has happened on this case yet." if timeline.empty?

    if kase.resolved?
      "Resolved #{on_day(kase.resolved_at)} as #{kase.resolution.tr('_', ' ')}."
    end
  end

  THREAD_GUARD_STATE = {
    "warned" => ["warned", "state-warn"],
    "running" => ["running", "state-warn"],
    "done" => ["done", "state-good"],
    "failed" => ["failed", "state-crit"]
  }.freeze

  def thread_guard_line(guard)
    text = guard.destroying? ? "Thread destroyed" : "Thread locked"
    safe_join([text, " in ", channel_link(guard.channel_id)])
  end

  def thread_guard_chip(guard)
    label, tone = THREAD_GUARD_STATE.fetch(guard.state, [guard.state, "state"])
    tag.span(label, class: "state #{tone}")
  end

  def guard_kind_options
    Fd::MemberGuard::KINDS.map { |key| [ACTION_LABELS.fetch(key, key), key] }
  end

  GUARD_CARRY_CHIP = {
    "held" => ["holding", "state-good"],
    "pending" => ["not yet", "state-warn"],
    "failed" => ["not holding", "state-crit"]
  }.freeze

  def guard_carry_chip(guard)
    return tag.span("by hand", class: "state") if guard.by_hand?

    label, tone = GUARD_CARRY_CHIP.fetch(guard.carry, [guard.carry, "state"])
    tag.span(label, class: "state #{tone}")
  end

  def already_here_note(attached)
    attached ? "already on this case" : "already logged on this case"
  end

  def thread_lock_note(guard, case_id)
    parts = [guard_standing_where(guard, case_id)]
    parts << (guard.expires_at ? "lifts #{guard.expires_at.strftime("%-d %b")}" : "no end date")
    parts << guard.reason.to_s.truncate(60)
    parts.join("  ·  ")
  end

  def guard_standing_where(guard, case_id)
    return "on no case" if guard.orphaned?
    return "on this case" if guard.case_id == case_id

    "on case #{guard.case_id}"
  end

  def guard_kind_line(guard)
    return action_label(guard.kind) unless guard.channel_scoped?

    safe_join([action_label(guard.kind), " in ", channel_link(guard.channel_id)])
  end

  def guard_held_line(guard)
    text = guard_kind_line(guard)
    guard.orphaned? ? safe_join([text, ", on no case"]) : text
  end

  def guard_option_note(guard, case_id)
    parts = [guard_standing_where(guard, case_id)]
    parts << (guard.expires_at ? "until #{guard.expires_at.strftime("%-d %b")}" : "no end date")
    parts.join("  ·  ")
  end

  def guard_already(guard)
    text = action_label(guard.kind).downcase
    return text unless guard.channel_scoped?

    safe_join([text, " in ", channel_link(guard.channel_id)])
  end

  def guard_whose(guard, case_id)
    return "on no case" if guard.orphaned?
    return "on this case" if guard.case_id == case_id

    link_to "under case #{guard.case_id}", fd_case_path(guard.case_id)
  end

  def guard_standing_line(guard, case_id, names = Names.none)
    safe_join([
      names[guard.subject_id],
      " is already ",
      guard_already(guard),
      " ",
      guard_whose(guard, case_id),
      "."
    ])
  end

  GUARD_CARRY = {
    "pending" => "nemo has not carried it yet",
    "failed" => "nemo is not holding it"
  }.freeze

  GUARD_CARRY_SAID = {
    "pending" => "Asking Slack",
    "held" => "Deactivated in Slack",
    "failed" => "Slack refused",
    "lifting" => "Putting the account back"
  }.freeze

  GUARD_DOT_TONE = {
    "pending" => "warn",
    "held" => "crit",
    "failed" => "crit",
    "lifting" => "good"
  }.freeze

  def guard_carry_label(guard)
    GUARD_CARRY_SAID.fetch(guard.carry_state, guard.carry_state)
  end

  def guard_dot_tone(guard)
    return "crit" if guard.failed?
    return GUARD_DOT_TONE.fetch(guard.carry_state, "act") if guard.deactivation?

    "act"
  end

  def guard_footnote(guard, names = Names.none)
    parts = ["opened by #{names[guard.opened_by]}"]
    parts << "since #{guard.opened_at.strftime("%-d %b")}" if guard.opened_at
    parts << (guard.expires_at ? "until #{guard.expires_at.strftime("%-d %b")}" : "with no end date")
    parts << if guard.by_hand?
      "done by hand"
    else
      GUARD_CARRY[guard.carry]
    end
    parts.compact.join("  \u00b7  ")
  end
  SETTLE_DEFAULT = {
    Fd::MemberGuard::UNGUARDED => Fd::MemberGuard::CARRY,
    Fd::MemberGuard::ORPHANED => Fd::MemberGuard::ADOPT,
    Fd::MemberGuard::ELSEWHERE => Fd::MemberGuard::RECORD,
    Fd::MemberGuard::HERE => Fd::MemberGuard::RECORD
  }.freeze
end
