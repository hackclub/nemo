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

  def linked_cases
    @linked_cases || {}
  end

  def usergroup_handles
    @usergroup_handles ||= Fd::SlackUsergroup::Handles.new
  end

  def channel_label(channel_id)
    channels[channel_id]
  end

  def channel_link(channel_id, permalink: nil)
    return tag.span(channels[channel_id], class: "sub2") if channel_id.blank?

    if permalink.present?
      return link_to(channels[channel_id], permalink, class: "handle",
        target: "_blank", rel: "noopener")
    end

    link_to channels[channel_id], slack_channel_url(channel_id), class: "handle",
      target: "_blank", rel: "noopener"
  end

  def handle(user_id)
    return "n/a" if user_id.blank?

    tag.button(person_name(user_id), type: "button", class: "handle", aria: { label: "Copy #{user_id}" },
      data: { controller: "copy", copy_id_value: user_id, action: "click->copy#write" })
  end

  CASE_QUEUE_PRIMARY_VIEWS = %w[attention unassigned mine].freeze

  MESSAGE_KIND_LABELS = { "them" => "Reporter", "us" => "Reply", "action" => "Action log" }.freeze

  def message_kind_label(kind)
    MESSAGE_KIND_LABELS[kind]
  end

  def member_event_byline(entry)
    return nil if entry.who.blank?
    return safe_join(["by ", member_link(entry.who)]) if entry.kind == "notes"

    safe_join(["assigned to ", member_link(entry.who)]) if entry.mark == "in"
  end

  def member_link(user_id)
    return "n/a" if user_id.blank?

    link_to person_name(user_id), fd_member_path(user_id), class: "lnk",
      data: { turbo_frame: "person-drawer" }
  end

  def member_face(user_id, deactivated: false)
    return "n/a" if user_id.blank?

    tag.span(class: ["member-face", ("is-gone" if deactivated)]) do
      safe_join([avatar(user_id), member_link(user_id)])
    end
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
    return locked_note("No identity") if identity.nil?
    return locked_note("No access") if identity.refused?
    return locked_note("Identity purged") if identity.purged?
    return locked_note("No email") if identity.email.blank?

    tag.span(class: "locked") { plain_email(identity.email, css: nil) }
  end

  def throwaway_email?(identity)
    return false if identity.nil? || identity.refused? || identity.purged? || identity.email.blank?

    Fd::ThrowawayDomain.listed?(identity.email)
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

  UNRESOLVED = /@([UW][A-Z0-9]{6,})\b/

  def named_text(text)
    safe_join(text.to_s.split(UNRESOLVED).each_with_index.map do |piece, i|
      i.odd? ? tag.span("@#{piece}", data: { cachet_name: piece }) : piece
    end)
  end

  def at_name(user_id)
    name = names[user_id]
    name.start_with?("@") ? name : "@#{name}"
  end

  def mentioned(text)
    return "" if text.blank?

    parts = Fd::Mentions.split(text).map do |piece|
      match = piece.match(Fd::Mentions::SLACK)
      next mention_link(match[1]) if match

      channel_match = piece.match(Fd::Mentions::CHANNEL)
      next channel_mention(channel_match[1], channel_match[2]) if channel_match

      link_match = piece.match(Fd::Mentions::LINK)
      next linked(link_match[1], link_match[2]) if link_match
      next linked(piece) if piece.match?(Fd::Mentions::BARE)

      piece
    end

    safe_join(parts)
  end

  def body_html(entry)
    blocks = entry.blocks.presence || Slack::Mrkdwn.blocks(entry.body)
    return echo_card_html(blocks) if Slack::EchoCard.echo?(blocks)

    blocks_html(blocks)
  end

  def blocks_html(blocks)
    Slack::RichText.for({ "blocks" => blocks }, **rendering)
  end

  def echo_card_html(blocks)
    Slack::EchoCard.render(blocks, **rendering)
  end

  def rendering
    { names: names, channels: channels, emoji: chat_emoji, usergroups: usergroup_handles,
      user_chip: ->(id) { mention_link(id) }, channel_chip: ->(id) { channel_mention(id) },
      link_chip: ->(url, label) { linked(url, label) } }
  end

  def linked(url, label = nil)
    href = CGI.unescapeHTML(url.to_s)
    return href unless href.start_with?("http://", "https://")

    target = linked_case(href)
    return case_link(target, (CGI.unescapeHTML(label.to_s) if labelled?(href, label))) if target

    link_to link_label(href, label), href, class: "link-note",
      target: "_blank", rel: "noopener"
  end

  def labelled?(href, label)
    text = CGI.unescapeHTML(label.to_s)
    text.present? && text != href
  end

  def linked_case(href)
    ref = Fd::SlackLink.parse(href)
    ref && linked_cases[[ref.channel_id, ref.thread_ts]]
  end

  def case_link(target, label = nil)
    link_to label || "Case #{target.case_id}",
      fd_case_path(target.root_id, tab: "report", thread: target.report_id),
      class: "link-note", data: { turbo_frame: "_top" }
  end

  def link_label(href, label = nil)
    return CGI.unescapeHTML(label.to_s) if labelled?(href, label)

    ref = Fd::SlackLink.parse(href)
    if ref
      return PRIVATE_DM_LABEL if ref.channel_id.match?(DM_ID)
      return "message in #{PRIVATE_CHANNEL_LABEL}" if channels.private_unnamed?(ref.channel_id)

      return "message in #{channel_label(ref.channel_id)}"
    end

    href.delete_prefix("https://").delete_prefix("http://").truncate(48)
  end

  def mention_link(user_id)
    link_to at_name(user_id), fd_member_path(user_id), class: "mention",
      data: { turbo_frame: "person-drawer" }
  end

  PRIVATE_CHANNEL_LABEL = "#private-channel".freeze
  PRIVATE_DM_LABEL = "private dm".freeze
  DM_ID = /\A[DG][A-Z0-9]+\z/

  def channel_mention(channel_id, name = nil)
    return dm_chip(channel_id) if channel_id.to_s.match?(DM_ID)
    return private_channel_chip(channel_id) if channels.private_unnamed?(channel_id)

    resolved_label = channels.named?(channel_id) ? channel_label(channel_id) : nil
    display_text = resolved_label || (name.present? ? "##{name}" : channel_id)
    return tag.span(display_text, class: "mention") unless may_open_channel?(channel_id)

    link_to display_text, fd_channel_path(channel_id), class: "mention",
      data: { turbo_frame: "_top" }
  end

  def dm_chip(channel_id)
    tag.span(PRIVATE_DM_LABEL, class: "mention mention-private")
  end

  def private_channel_chip(channel_id)
    tag.span(PRIVATE_CHANNEL_LABEL, class: "mention mention-private")
  end

  def may_open_channel?(channel_id)
    return false unless on?(:analytics)
    return true unless respond_to?(:current_account)

    @may_open ||= {}
    @may_open.fetch(channel_id) {
      @may_open[channel_id] = Channels::Audience.may_see?(current_account, channel_id)
    }
  end

  def share_of(part, total)
    return "n/a" if total.to_i.zero?

    "#{((part.to_f / total) * 100).round(1)}% of the workspace"
  end

  AUDIT_SOURCE = { "fire_engine" => "Fire Engine", "slack" => "Slack", "access_logs" => "Slack access log",
                   "read" => "Fire Engine", "api" => "API" }.freeze

  def audit_raw(row)
    JSON.pretty_generate(row.raw || row.detail || {})
  end

  def audit_verb(row)
    row.verb.to_s.tr("_", " ")
  end

  def audit_actor(row)
    return member_face(row.actor_id) if row.actor_id.present?
    return tag.span("Nemo", class: "state") if row.actor_kind.to_s == "bot"

    tag.span("Unknown", class: "state")
  end

  AUDIT_CHANNEL = /\A[CGD][A-Z0-9]{2,}\z/
  AUDIT_MEMBER = /\A[UW][A-Z0-9]{2,}\z/

  def audit_about(row)
    return member_face(row.subject_id) if row.subject_id.present?

    refs = [row.entity_ref, row.entity_id].compact_blank
    channel_id = refs.find { |ref| ref.match?(AUDIT_CHANNEL) }
    return audit_channel(channel_id) if channel_id

    member_id = refs.find { |ref| ref.match?(AUDIT_MEMBER) }
    return member_face(member_id) if member_id
    return tag.span("#{row.entity_kind} #{row.entity_id}", class: "sub2") if row.entity_id.present?

    tag.span(row.entity_kind.to_s.tr("_", " "), class: "sub2")
  end

  PRIVATE_CHANNEL = "#private-channel".freeze

  def audit_channel(channel_id)
    return tag.span(PRIVATE_CHANNEL, class: "sub2") unless
      channels.named?(channel_id)

    link_to channel_label(channel_id), channel_path(channel_id), class: "lnk"
  end

  AUDIT_VALUE = 80

  def audit_value(value)
    return tag.span("empty", class: "sub2") if value.nil? || value == ""

    text = value.is_a?(String) ? value : value.to_json
    tag.span(text.truncate(AUDIT_VALUE), class: "mono")
  end

  DOMAIN_MATCH_LABELS = { "exact" => "exact", "suffix" => "with subdomains" }.freeze
  DOMAIN_EFFECT_LABELS = { "flag" => "flag", "hold" => "shush",
                           "deactivate" => "deactivate" }.freeze
  DOMAIN_EFFECT_TONES = { "flag" => "", "hold" => "state-warn",
                          "deactivate" => "state-crit" }.freeze
  SCREEN_TONES = { "flagged" => "state-warn", "held" => "state-warn",
                   "deactivated" => "state-crit", "failed" => "state-crit" }.freeze

  def domain_match_label(key) = DOMAIN_MATCH_LABELS.fetch(key, key)

  def domain_effect_label(key) = DOMAIN_EFFECT_LABELS.fetch(key, key)

  def domain_match_chip(domain)
    tag.span(domain_match_label(domain.match_mode), class: "state")
  end

  def domain_effect_chip(domain)
    tag.span(domain_effect_label(domain.effect),
      class: "state #{DOMAIN_EFFECT_TONES.fetch(domain.effect, '')}".strip)
  end

  def screen_outcome_chip(screen)
    tag.span(screen.outcome.tr("_", " "),
      class: "state #{SCREEN_TONES.fetch(screen.outcome, '')}".strip)
  end

  def link_band_chip(side)
    tone = { "certain" => "state-crit", "strong" => "state-warn" }.fetch(side.band, "")
    tag.span(LinkHelper::BAND_LABELS.fetch(side.band), class: "state #{tone}".strip)
  end

  def may_judge? = current_account&.may?("link.verdict")

  def verdict_chip(verdict)
    return "" if verdict.nil?

    title = ["by #{names[verdict.decided_by]}", verdict.note].compact.join(", ")
    tag.span(verdict.label, class: "state #{verdict.one_person? ? 'state-crit' : 'state-good'}", title: title)
  end

  def verdict_cell(user_id, other_user_id, verdict = nil, back: request.fullpath)
    tag.div(safe_join([verdict_chip(verdict), link_review_button(user_id, other_user_id, verdict&.verdict, back: back)]
      .compact_blank), class: "verdict-cell")
  end

  def session_span(first_at, last_at)
    return "n/a" if first_at.nil? || last_at.nil?
    return on_day(last_at) if first_at.to_date == last_at.to_date

    "#{first_at.strftime('%-d %b')} \u2013 #{on_day(last_at)}"
  end

  def session_swatch(address)
    return tag.span("Shared", class: "state state-crit") if address.other_user_ids.any?
    return tag.span("Many users", class: "state") if address.shared_range?
    return tag.span("Shared", class: "state state-warn") if address.shared?

    tag.span("Not shared", class: "state state-good")
  end

  def new_member_country(row)
    return tag.span("n/a", class: "sub2") if row.last_country.blank?

    safe_join([
      (tag.span(row.flag, class: "new-member-flag") if row.flag),
      tag.span(Fd::Countries.name_for(row.last_country))
    ].compact, " ")
  end

  def new_member_ip(row)
    return tag.span("never signed in", class: "sub2") if row.ip.blank?

    safe_join([
      tag.span(row.ip, class: "mono"),
      (if row.shared_range?
         tag.span("#{row.ip_user_count} users", class: "state state-warn")
       elsif row.shares_ip?
         tag.span("#{row.ip_user_count} users", class: "state")
       end)
    ].compact, " ")
  end

  def new_member_sort_header(label, key, numeric: false)
    css = ["th-sort"]
    css << "col-num" if numeric
    css << (@query.descending? ? "sort-down" : "sort-up") if @query.sorting?(key)

    tag.th(class: css.join(" "), aria: { sort: sort_state(key) }) do
      link_to fd_new_members_path(@query.sort_params(key)) do
        concat tag.span(label)
        concat sort_caret(key)
      end
    end
  end

  NEW_MEMBER_SOURCE = { "by_hand" => "manual",
                        "cohort" => "cohort table" }.freeze

  def new_member_when(row)
    [row.joined_at.strftime("%-d %b %Y"), NEW_MEMBER_SOURCE[row.source]].compact.join(" · ")
  end

  def new_member_standing(row)
    return tag.span("Deactivated", class: "state state-crit") if row.deactivated?
    return tag.span("Clear", class: "state") unless row.guarded?

    safe_join(Fd::MemberGuard.kinds_by_severity(row.kinds).map { |kind|
      tag.span(action_label(kind), class: "state state-warn")
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

  def on_day(time, none: "n/a")
    time ? time.to_time.strftime("%-d %b %Y") : none
  end

  def clock_stamp(time, format = "%-d %b %H:%M")
    local = time.in_time_zone
    tag.time(local.strftime(format), datetime: local.iso8601, title: time.utc.strftime("%-d %b %Y %H:%M UTC"))
  end

  def ago_label(time, none: "n/a")
    return none if time.nil?

    days = (Date.current - time.to_time.to_date).to_i
    return "today" if days <= 0
    return "yesterday" if days == 1
    return "#{days}d ago" if days < 30

    on_day(time)
  end

  def lane_run_label(run)
    return "n/a" if run.never?
    return safe_join(["running", tag.span("started #{time_ago(run.started_at)}", class: "fact-note")], " ") if run.running?

    note = run.ok? ? "took #{duration_label(run.seconds)}" : run.status
    safe_join([time_ago(run.finished_at), tag.span(note, class: "fact-note")], " ")
  end

  def lane_steps_label(run)
    return nil if run.steps.blank?

    tag.span(run.steps.map { |step| "#{step.name} #{format('%.1f', step.seconds)}s" }.join(", "), class: "fact-note lane-steps")
  end

  def member_standing_swatch(row)
    word, tone =
      if row.open_cases.positive? then ["Open case", "state-warn"]
      elsif row.in_force.positive? then ["In force", "state-crit"]
      elsif row.notes.positive? || row.cases.positive? then ["Noted", "state-warn"]
      else ["Clean", "state-off"]
      end

    tag.span(word, class: "state #{tone}")
  end

  def wrong_on?(field)
    flash[:field_error].is_a?(Hash) && flash[:field_error]["field"] == field.to_s
  end

  def field_wrong(field)
    return nil unless wrong_on?(field)

    tag.p(flash[:field_error]["message"], class: "field-wrong")
  end

  def submitted_value(field, fallback = nil)
    wrong_on?(field) ? flash[:field_error]["was"] : fallback
  end

  def member_tab_link(user_id, key, label, count)
    link_to fd_member_path(user_id, (@pane_params || {}).merge(tab: (key unless key == "history")).compact),
      class: "view", aria: { current: ("true" if key == @tab) },
      data: { turbo_frame: "member-record", turbo_action: "advance" } do
      concat tag.span(label)
      concat tag.span(count, class: "tab-count") if count
    end
  end

  def member_tab_count(key)
    case key
    when "history" then @entries.size
    when "links" then @member_links&.count
    when "purges" then @purge_count if @purge_count&.positive?
    end
  end

  MEMBER_ACCOUNT_TONES = { "active" => "state-good", "invite_pending" => "state-warn",
                           "claimed_no_sign_in" => "state-warn" }.freeze

  def member_account_tone(state) = MEMBER_ACCOUNT_TONES[state]

  def guard_ends(guard)
    return "#{guard.deactivation? ? 'Reactivated' : 'Lifted'} #{on_day(guard.lifted_at)}" if guard.lifted_at
    return Fd::ShortDate.ending(guard.expires_at) if guard.expires_at

    "No end date"
  end

  def menu_item(icon, label, note: nil)
    render "fd/menu_item", icon: icon, label: label, note: note
  end

  Stop = Struct.new(:key, :label, :icon, :path, :current, :tally, keyword_init: true)

  NAV_HOME = { "fd/fire" => "overview", "fd/members" => "members",
               "fd/new_members" => "new_members", "fd/clusters" => "clusters",
               "fd/channels" => "channels", "fd/audits" => "audit",
               "fd/configuration" => "configuration",
               "fd/channel_purges" => "channels", "fd/member_purges" => "members" }.freeze

  def fd_current_nav_key
    if controller_path == "fd/member_links"
      return Fd::LinkList::VIEWS.key?(params[:view].to_s) && params[:view].to_s != Fd::LinkList::DEFAULT_VIEW ? "pairs" : "review"
    end

    NAV_HOME.fetch(controller_path, "cases")
  end

  def fd_nav_stops
    fd_nav_mark([
      Stop.new(key: "overview", label: "Overview", icon: "overview", path: fd_root_path),
      Stop.new(key: "cases", label: "Cases", icon: "shield", path: fd_cases_path,
        tally: Fd::Case.unresolved.not_duplicate.unassigned.count),
      Stop.new(key: "members", label: "Members", icon: "people", path: fd_members_path),
      Stop.new(key: "channels", label: "Channels", icon: "channels", path: fd_channels_path),
      Stop.new(key: "new_members", label: "New members", icon: "newcomers",
        path: fd_new_members_path)
    ])
  end

  def fd_nav_alts
    return [] unless current_account&.may?("member.links")

    fd_nav_mark([
      Stop.new(key: "review", label: "Review", icon: "inbox", path: fd_links_path,
        tally: Fd::MemberLink.review_count),
      Stop.new(key: "clusters", label: "Clusters", icon: "network", path: fd_clusters_path),
      Stop.new(key: "pairs", label: "Links", icon: "link", path: fd_links_path(view: "certain"))
    ])
  end

  def fd_nav_records
    return [] unless current_account&.may?("access.read") || current_account&.may?("audit.read")

    fd_nav_mark([Stop.new(key: "audit", label: "Audit log", icon: "history", path: fd_audit_path)])
  end

  def fd_nav_tools
    return [] unless current_account&.may?("app.configure")

    fd_nav_mark([Stop.new(key: "configuration", label: "Configuration", icon: "gear",
      path: fd_configuration_path)])
  end

  def fd_nav_groups
    stops = fd_nav_stops.index_by(&:key)
    [
      [nil, stops.values_at("overview", "cases")],
      ["People", stops.values_at("members", "new_members")],
      ["Alts", fd_nav_alts],
      ["Records", fd_nav_records],
      ["Manage", fd_nav_tools + stops.values_at("channels")]
    ].reject { |_, group| group.empty? }
  end

  def fd_nav_mark(stops)
    current_key = fd_current_nav_key
    stops.each { |stop| stop.current = stop.key == current_key }
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

  REMOVE_LABELS = {
    "subject" => "Remove as subject",
    "reporter" => "Remove as reporter"
  }.freeze

  def remove_person_label(person, record)
    return "Remove from case" if person.records.one?

    REMOVE_LABELS.fetch(record.role, "Remove as #{record.role}")
  end

  def age_class(seconds)
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

    years, remaining_months = months.divmod(12)
    remaining_months.zero? ? "#{years}y" : "#{years}y #{remaining_months}mo"
  end

  ROLE_LABELS = {
    "subject" => "subject",
    "reporter" => "reporter"
  }.freeze

  def slack_thread_url(channel_id, thread_ts)
    Fd::SlackLink.url_for(channel_id, thread_ts)
  end

  def role_label(role)
    ROLE_LABELS.fetch(role, role)
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
    files = Fd::IntakeFile.for_messages(messages.map(&:id))
    cited = Fd::IntakeShare.for_messages(messages.map(&:id))
    entries = messages.map do |message|
      message_entry(message, hidden, files.fetch(message.id, []), cited.fetch(message.id, []))
    end
    relayed = Fd::CaseReport.shroud_reports_by_thread(chat)
    entries += chat.filter_map do |line|
      report = relayed[[line.channel_id, line.thread_ts]] if Fd::CaseReport.shroud_relay?(line)
      next if report && reports.exclude?(report)

      chat_entry(line, report)
    end
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
    from_member = message.theirs?
    masked = from_member && hidden
    ChatEntry.new(
      key: "msg-#{message.id}",
      at: message.posted_at,
      side: from_member ? "in" : "out",
      kind: from_member ? "them" : "us",
      who: masked ? nil : (from_member ? message.author_user_id : message.sent_by),
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
    return "Reporter" if message.theirs?
    return names[message.sent_by] if message.sent_by

    "Fire Department"
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

  def chat_entry(line, report = nil)
    return relayed_entry(line, report) if report && Fd::CaseReport.shroud_relay?(line)
    return root_entry(line) if line.id == @root_chat&.id

    blocks = line.blocks unless line.deleted?
    kind = Slack::EchoCard.echo?(blocks) ? "action" : "chat"
    ChatEntry.new(key: "chat-#{line.id}", at: line.posted_at, side: "out", kind: kind,
      who: line.author_user_id, name: names[line.author_user_id], body: chat_body(line),
      blocks: blocks)
  end

  def relayed_entry(line, report)
    ChatEntry.new(key: "chat-#{line.id}", at: line.posted_at, side: "in", kind: "them",
      who: (report.reporter_user_id unless report.anonymous?), anon: report.anonymous?,
      name: report.reporter_label(names), body: chat_body(line), blocks: (line.blocks unless line.deleted?))
  end

  def root_entry(line)
    ChatEntry.new(key: "chat-#{line.id}", at: line.posted_at, side: "in", kind: "them",
      who: line.author_user_id, name: names[line.author_user_id], body: chat_body(line),
      blocks: (line.blocks unless line.deleted?))
  end

  def chat_body(line)
    return "#{line.body} (deleted in Slack)" if line.deleted?

    line.body
  end

  def merge_candidate_line(kase)
    assignee_note = if kase.assigned?
      "assigned to #{names.list(kase.assignee_user_ids)}"
    elsif !kase.resolved?
      "unassigned"
    end
    ["opened #{on_day(kase.opened_at)}", assignee_note].compact.join(" · ")
  end

  def merge_primary_line(plan)
    "Primary case ##{plan.primary.id}"
  end

  def merge_duplicates_line(plan)
    numbers = plan.merged_cases.map { |kase| "##{kase.id}" }.to_sentence
    "Duplicates: #{numbers}"
  end

  def merge_counts(plan)
    [
      pluralize(plan.reports, "report thread"),
      pluralize(plan.threads, "evidence thread"),
      pluralize(plan.actions, "action"),
      pluralize(plan.notes, "note"),
      pluralize(plan.participant_count, "person", plural: "people")
    ].join(" · ")
  end

  def composer_hint(thread)
    thread.nil? ? "Message the team" : "Message"
  end

  def thread_state(report, kase, reachable)
    if !reachable.include?(report.id)
      ["closed", "closed"]
    elsif report.unanswered? && !kase.resolved?
      ["waiting #{case_age_label(report.waiting_for)}", "waiting"]
    else
      [report.received_at.strftime("%-d %b"), nil]
    end
  end

  def thread_face(report)
    return anonymous_face(css: "row-avatar thread-face") if report.anonymous?

    avatar(report.reporter_user_id, css: "row-avatar thread-face")
  end

  def chat_empty_title(kase, reports)
    return "Not imported yet" if kase.chat_import_pending?

    reports.any? ? "No messages" : "No report on file"
  end

  def chat_head_line(reports, kase, count: 0)
    parts = []
    parts << "case #{reports.first.case_id}" if kase.merged?
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

  def resolution_label(key)
    RESOLUTION_LABELS.fetch(key, key.to_s.tr("_", " "))
  end

  def closing_reason(actions)
    labels = actions.map { |action| action_label(action.type_key).downcase }.uniq.to_sentence
    "action taken, #{labels}"
  end

  def close_reason_options
    Fd::Case::CLOSE_REASONS.map { |key| [resolution_label(key), key] }
  end

  ACTION_GROUP_LABELS = { false => "Actions", true => "Account deactivation" }.freeze

  def action_options
    ACTION_LABELS.map do |key, label|
      [label, key, { data: {
        expires: Fd::Action::TAKES_EXPIRY.include?(key),
        channel: Fd::Action::TAKES_CHANNEL.include?(key),
        lock: Fd::Action.from_thread_lock?(key),
        deactivates: Fd::Action.deactivates?(key)
      } }]
    end
  end

  def action_select_options
    grouped = action_options.group_by { |_label, key, _attributes| Fd::Action.deactivates?(key) }
    grouped_options_for_select(
      ACTION_GROUP_LABELS.filter_map { |deactivates, label| [label, grouped[deactivates]] if grouped[deactivates] }
    )
  end

  CONFIGURATION_TAB_LABELS = { "automod" => "Automod", "domains" => "Domains",
                              "responses" => "Responses", "public_log" => "Public log",
                              "categories" => "Categories",
                              "tags" => "Tags" }.freeze

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
    Fd::InfractionCategory.active_keys.map { |key| [category_label(key), key] }
  end

  def action_category_options(action)
    options = [["Not set", ""]] + category_options
    current = action.category_key
    return options if current.blank? || options.any? { |_label, key| key == current }

    options + [[category_label(current), current]]
  end

  def note_byline(note)
    parts = [member_link(note.author), on_day(note.created_at)]
    parts << "edited" if note.edited?
    safe_join(parts, " · ")
  end

  def action_option_label(action)
    parts = [action_label(action.type_key)]
    parts << "on #{names[action.target_user_id]}" if action.targets_member?
    parts << on_day(action.performed_at)
    parts.join(" · ")
  end

  def sole_subject_id(kase)
    ids = kase.subject_user_ids
    ids.first if ids.one?
  end

  def subject_handles(kase)
    ids = kase.subject_user_ids
    return "No subject" if ids.empty?
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
    return safe_join([person_name(kase.opened_by), " opened it"]) if reports.empty?

    identified_reports = reports.reject(&:anonymous?)
    return "#{pluralize(reports.size, 'person')} reported it" if reports.many?
    return "a member reported it" if identified_reports.empty?

    safe_join([person_name(identified_reports.first.reporter_user_id), " reported it"])
  end

  def row_messages_phrase(kase, thread_counts, thread_channels)
    count = thread_counts.fetch(kase.id, 0)
    return nil unless count.positive?

    text = pluralize(count, "message")
    channel_ids = Array(thread_channels[kase.id])
    return text unless channel_ids.one? && channels.named?(channel_ids.first)

    "#{text} in #{channels[channel_ids.first]}"
  end

  AVATAR_TONES = 8

  def avatar_tone(user_id)
    return "avatar-none" if user_id.blank?

    "avatar-#{(user_id.sum % AVATAR_TONES) + 1}"
  end

  SUBJECT_FACE_LIMIT = 3

  def subject_faces(kase)
    ids = kase.subject_user_ids
    return nil if ids.empty?

    visible_ids = ids.first(SUBJECT_FACE_LIMIT)
    parts = visible_ids.map { |id|
      tag.span(class: "face-name") {
        safe_join([slack_face(id), tag.span(member_link(id), class: "face-sub")])
      }
    }
    parts << tag.span("+#{ids.size - visible_ids.size}", class: "face-more") if ids.size > visible_ids.size
    tag.span(class: ["subjfaces", ("subjfaces-many" if ids.many?)]) { safe_join(parts) }
  end

  def preset_faces(user_ids)
    ids = Array(user_ids).compact.reject(&:blank?).uniq
    return [] if ids.empty?

    name_lookup = Fd::Names.for(ids)
    ids.map { |id| { id: id, name: name_lookup[id], initial: name_lookup.member(id)&.initial || id[0] } }
  end

  def slack_face(user_id, css: "row-avatar")
    return avatar(user_id, css: css) if user_id.blank?

    link_to slack_member_url(user_id), class: "face-link", target: "_blank",
      rel: "noopener", aria: { label: "#{names[user_id]} in Slack" } do
      avatar(user_id, css: css)
    end
  end

  def avatar(user_id, css: "row-avatar", data: {})
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

  LINK_PATTERN = %r{<https?://[^\s<>|]+(?:\|[^>]*)?>|https?://\S+}

  def only_a_link?(text)
    text = text.to_s
    !text.empty? && text.gsub(LINK_PATTERN, " ").blank?
  end

  def plain_text(text)
    named_text(Slack::PlainText.for(Slack::Mrkdwn.blocks(text), names: names, channels: channels,
      usergroups: usergroup_handles))
  end

  def case_cited(kase)
    cited = cited_words[kase.id]
    return nil if cited.nil? || cited.body.blank?

    body = case_first_report(kase)&.body.presence
    return nil if body.present? && !only_a_link?(body)

    cited
  end

  def attachment_counts
    @attachment_counts || {}
  end

  def case_roots
    @case_roots || {}
  end

  def case_words(kase)
    body = case_first_report(kase)&.body.presence
    return plain_text(body) if body
    return case_root_words(kase) if kase.reports.empty?

    attachment_count = attachment_counts[kase.id].to_i
    return pluralize(attachment_count, "attachment") if attachment_count.positive?

    "Empty report"
  end

  def case_root_words(kase)
    body = case_roots[kase.id]&.body.presence
    body ? plain_text(body) : "No report"
  end

  def row_reporter(kase)
    reports = kase.reports.to_a
    return case_roots[kase.id]&.author_user_id || kase.opened_by if reports.empty?

    reports.reject(&:anonymous?).first&.reporter_user_id
  end

  ANONYMOUS_FACE = "/anonymous.png".freeze

  def anonymous_face(css: "row-avatar")
    image_tag(ANONYMOUS_FACE, class: css, alt: "", width: 22, height: 22,
      loading: "lazy")
  end

  def row_reporter_face(kase)
    reporter_id = row_reporter(kase)
    return avatar(reporter_id) if reporter_id.present?

    anonymous_face
  end

  def case_priors(kase, counts)
    counts[kase.subject_user_id].to_i
  end

  def row_reporter_label(kase)
    reporter_id = row_reporter(kase)
    return "Anonymous" if reporter_id.blank?

    other_count = kase.reports.size - 1
    return names[reporter_id] if other_count < 1

    "#{names[reporter_id]} and #{pluralize(other_count, 'other')}"
  end

  PRIOR_TONES = { 0 => "chip-good", 1 => "chip-off" }.freeze

  def prior_phrase(count)
    case count
    when 0 then "no priors"
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
    return tag.span(kase.resolution.tr("_", " ").upcase_first, class: "state state-off") if kase.resolved?

    tag.span("Open", class: "state state-crit")
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
    parts.compact.any? ? safe_join(parts.compact, " · ") : nil
  end

  def reversal_line(action)
    reason_suffix = action.reversal_reason.present? ? ", #{action.reversal_reason}" : ""
    safe_join(["reversed #{on_day(action.reversed_at)} by ", person_name(action.reversed_by), reason_suffix])
  end

  def action_thread_url(action)
    return nil unless action.from_thread_lock?

    channel = action.details["channel_id"]
    thread = action.details["thread_ts"]
    return nil if channel.blank? || thread.blank?

    slack_thread_url(channel, thread)
  end

  def action_state_chip(action)
    return tag.span("Reversed", class: "chip chip-off") if action.reversed?
    return tag.span("Expired #{Fd::ShortDate.ending(action.expires_at)}", class: "chip chip-off") if action.expired?

    return nil unless action.expires?

    remaining = case_age_label(action.expires_at - Time.current)
    tag.span("In force, #{remaining} left", class: "chip chip-warn")
  end

  def action_sentence(action)
    channel = action.details["channel_id"]
    parts = action.targets_member? ? ["On ", member_link(action.target_user_id)] : ["On a thread"]
    parts << " in #{channel_label(channel)}" if channel.present?
    parts << ", until #{Fd::ShortDate.ending(action.expires_at)}" if action.expires?
    parts << ". Set by "
    parts << member_link(action.decided_by)
    parts << " on #{on_day(action.performed_at)}."
    if action.resolved_by.present? && action.resolved_by != [action.decided_by]
      parts << " Resolved by "
      parts << safe_join(action.resolved_by.map { |user_id| member_link(user_id) }, ", ")
      parts << "."
    end
    safe_join(parts)
  end

  def violations_label(keys, short: false)
    return nil if keys.empty?

    keys.map { |key| short ? category_short(key) : category_label(key) }.join(", ")
  end

  def action_reason(action)
    reason = action.reason.presence
    return tag.span("No reason", class: "why-none") if reason.nil?

    tag.q(reason, class: "why-quote")
  end

  def action_solution(action)
    tag.span(action.solution, class: "why-quote")
  end

  def action_performer_note(action)
    return "performed by decider" if action.performed_by_decider?

    safe_join(["performed by ", person_name(action.performed_by)])
  end

  def fact_number(value)
    value ? number_with_delimiter(value) : "n/a"
  end

  def member_since(context)
    cohort_at = context&.cohort_at
    return "n/a" if cohort_at.nil?

    "#{cohort_at.to_date.strftime('%b %Y')} &middot; #{tenure_label(context.tenure_days)}".html_safe
  end

  def last_active_label(time)
    ago_label(time)
  end

  ROLE_CHIPS = { "community_manager" => ["chip-crit", "manager"],
                 "lead" => ["chip-warn", "lead"],
                 "firefighter" => ["chip-off", "firefighter"] }.freeze

  def role_chip(role)
    tone, label = ROLE_CHIPS.fetch(role, ["chip-off", role])
    tag.span(label, class: "chip #{tone}")
  end

  def flag_switch(key)
    enabled = Fd::Flag.on?(key)
    return nil unless current_account.may?("app.flip")

    button_to enabled ? "yes" : "no",
      fd_flag_path(key: key, on: enabled ? "0" : "1"),
      method: :patch, class: "switch #{enabled ? 'yes' : 'no'}",
      aria: { label: "#{enabled ? 'Turn off' : 'Turn on'} #{Fd::Flag.label(key).downcase}" },
      form: { class: "contents" }
  end

  def last_action_label(time)
    ago_label(time, none: "never")
  end

  AUDIT_SUMMARIES = {
    "case/opened" => "Opened",
    "case/claimed" => "Claimed",
    "case/unclaimed" => "Released",
    "case/resolved" => "Resolved",
    "case/reopened" => "Reopened",
    "case/categorised" => "Set category on",
    "note/noted" => "Wrote a note on",
    "note/deleted" => "Deleted a note on",
    "note/edited" => "Edited a note on",
    "participant/attached" => "Added person to",
    "participant/detached" => "Removed person from",
    "assignee/attached" => "Assigned",
    "assignee/detached" => "Unassigned",
    "assignee/claimed" => "Claimed",
    "assignee/unclaimed" => "Released",
    "thread/attached" => "Attached a thread to",
    "thread/detached" => "Detached a thread from",
    "citation/flagged" => "Flagged a message on",
    "citation/unflagged" => "Unflagged a message on",
    "action/performed" => "Logged an action on",
    "action/reversed" => "Reversed an action on",
    "action/edited" => "Edited an action on",
    "member/looked_up" => "Looked up",
    "report/received" => "Received report on",
    "report/closed" => "Notified reporter on",
    "consent/granted" => "Opted in to",
    "consent/withheld" => "Opted out of",
    "api/checked" => "Checked",
    "api/setting_changed" => "Changed the",
    "api/token_minted" => "Generated a token,",
    "api/token_rate_set" => "Set the rate on",
    "api/token_revoked" => "Revoked a token,",
    "grant/granted" => "Granted access to",
    "grant/revoked" => "Revoked access from",
    "permission/granted" => "Role capability granted",
    "permission/revoked" => "Role capability revoked",
    "identity/read" => "Read the identity of",
    "slack_account/linked" => "Linked their Slack account",
    "slack_account/unlinked" => "Unlinked their Slack account"
  }.freeze

  def why_not(key, record = nil)
    Fd::Access.why_not(current_account, key, record)
  end

  def opens_modal(key, text = nil, opens:, on: nil, css: "btn", data: {}, &block)
    denied_reason = why_not(key, on)
    body = block ? capture(&block) : text
    if denied_reason.nil?
      return tag.button(body, type: "button", class: css,
        data: data.merge(modal_open: opens),
        aria: { haspopup: "dialog" })
    end

    disabled_button(body, denied_reason, css)
  end

  def gated_button(key, text, path, on: nil, css: "btn", **options)
    denied_reason = why_not(key, on)
    return disabled_button(text, denied_reason, css) if denied_reason

    form = { class: "contents" }.merge(options.delete(:form) || {})
    button_to text, path, class: css, form: form, **options
  end

  def disabled_button(text, denied_reason, css = "btn")
    tag.span(class: "#{css} btn-off", tabindex: "0",
      aria: { disabled: "true", description: denied_reason }) do
      concat tag.span(text)
      concat tag.span(denied_reason, class: "btn-why")
    end
  end

  def audit_summary(event)
    AUDIT_SUMMARIES.fetch(event) { event.tr("_/", " ").capitalize }
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

  SETTING_LABELS = {
    "rate_per_minute" => "Requests per minute per key",
    "batch_max" => "People per batch call",
    "tokens_per_owner" => "Live keys per app"
  }.freeze

  def setting_label(key)
    SETTING_LABELS.fetch(key, key.tr("_", " "))
  end

  ACCESS_CHIPS = { "approved" => "chip-good", "declined" => "chip-crit",
                   "withdrawn" => "chip-off", "pending" => "chip-warn" }.freeze

  def access_state_chip(state)
    tag.span(state.to_s.upcase_first, class: "chip #{ACCESS_CHIPS.fetch(state, 'chip-off')}")
  end

  def withheld_percentage(withheld, checks)
    return "n/a" if checks.zero?

    "#{(withheld * 100.0 / checks).round(1)}% of checks"
  end

  def synced_line(synced_at)
    return "Never" if synced_at.nil?

    channel_count = Api::ChannelSweep.count
    "#{synced_at.in_time_zone.strftime('%-d %b %H:%M')}, #{channel_count} #{'channel'.pluralize(channel_count)}"
  end

  def setting_applies_to(key, tokens)
    live = tokens.reject(&:revoked?)
    return "#{live.count { |token| token.rate_limit.nil? }} of #{live.size}" if key == "rate_per_minute"

    "all"
  end

  def setting_last_change(setting)
    return "Never" if setting.nil? || setting.changed_by.blank?

    safe_join([person_name(setting.changed_by), ", #{setting.changed_at.strftime('%-d %b')}"])
  end

  def refused_note(kinds)
    return "none in 30 days" if kinds.empty?

    kinds.map { |key, count| "#{count} #{key}" }.join(" · ")
  end

  def timeline_standing(kase, timeline)
    return "No events" if timeline.empty?

    if kase.resolved?
      "Resolved #{on_day(kase.resolved_at)} · #{kase.resolution.tr('_', ' ')}"
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

  GUARD_ENFORCEMENT_CHIP = {
    "held" => ["Enforced", "state-good"],
    "pending" => ["Pending", "state-warn"],
    "failed" => ["Not enforced", "state-crit"]
  }.freeze

  DEACTIVATION_CHIP = {
    "held" => ["Deactivated", "state-good"],
    "pending" => ["Pending", "state-warn"],
    "failed" => ["Not deactivated", "state-crit"]
  }.freeze

  def guard_enforcement_chip(guard)
    return tag.span("By hand", class: "state") if guard.by_hand?
    return tag.span("Firehose", class: "state") if guard.firehose?
    return tag.span(LOGGED_ONLY, class: "state") if guard.logged_only?

    chips = guard.deactivation? ? DEACTIVATION_CHIP : GUARD_ENFORCEMENT_CHIP
    label, tone = chips.fetch(guard.enforcement_status, [guard.enforcement_status, "state"])
    tag.span(label, class: "state #{tone}")
  end

  def already_attached_note(attached)
    attached ? "already on this case" : "already logged on this case"
  end

  def thread_lock_note(guard, case_id)
    parts = [guard_standing_where(guard, case_id)]
    parts << (guard.expires_at ? "lifts #{Fd::ShortDate.ending(guard.expires_at)}" : "no end date")
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

  def guard_line(guard)
    text = guard_kind_line(guard)
    guard.orphaned? ? safe_join([text, ", on no case"]) : text
  end

  def guard_option_note(guard, case_id)
    parts = [guard_standing_where(guard, case_id)]
    parts << (guard.expires_at ? "until #{Fd::ShortDate.ending(guard.expires_at)}" : "no end date")
    parts.join("  ·  ")
  end

  GUARD_ENFORCEMENT_STATUS = {
    "pending" => "Enforcement pending",
    "failed" => "Not enforced"
  }.freeze

  DEACTIVATION_STATUS = {
    "pending" => "Deactivation pending",
    "failed" => "Not deactivated"
  }.freeze

  LOGGED_ONLY = "Logged only".freeze

  GUARD_ENFORCEMENT_STATE_LABELS = {
    "pending" => "Pending",
    "held" => "Deactivated in Slack",
    "failed" => "Rejected by Slack",
    "lifting" => "Reactivating"
  }.freeze

  GUARD_DOT_TONE = {
    "pending" => "warn",
    "held" => "crit",
    "failed" => "crit",
    "lifting" => "good"
  }.freeze

  def guard_enforcement_label(guard)
    return LOGGED_ONLY if guard.logged_only? && !guard.lifting?

    GUARD_ENFORCEMENT_STATE_LABELS.fetch(guard.enforcement_state, guard.enforcement_state)
  end

  def guard_dot_tone(guard)
    return "crit" if guard.failed?
    return "act" if guard.logged_only?
    return GUARD_DOT_TONE.fetch(guard.enforcement_state, "act") if guard.deactivation?

    "act"
  end

  def guard_footnote(guard, names = Names.none)
    opener = names.unknown?(guard.opened_by) ? tag.span(names[guard.opened_by], data: { cachet_name: guard.opened_by }) : names[guard.opened_by]
    parts = [safe_join(["Opened by ", opener])]
    parts << "since #{Fd::ShortDate.for(guard.opened_at)}" if guard.opened_at
    parts << (guard.expires_at ? "until #{Fd::ShortDate.ending(guard.expires_at)}" : "with no end date")
    parts << if guard.by_hand?
      "by hand"
    elsif guard.firehose?
      "Firehose"
    elsif guard.deactivation?
      DEACTIVATION_STATUS[guard.enforcement_status]
    else
      GUARD_ENFORCEMENT_STATUS[guard.enforcement_status]
    end
    safe_join(parts.compact, " \u00b7 ")
  end
end
