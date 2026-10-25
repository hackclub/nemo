require "test_helper"

class FdHelperTest < ActionView::TestCase
  include FdHelper

  def on?(_key) = true

  def kase(**attrs)
    make_case(opened_at: 5.days.ago, **attrs)
  end

  def entries(count)
    Array.new(count) { Fd::CaseTimeline::Entry.new(at: Time.current, title: "x") }
  end

  test "channel_mention links to the fd channel page in the top frame" do
    html = channel_mention("C0BE6N4G2BA")

    assert_match(%r{href="/fd/channels/C0BE6N4G2BA"}, html)
    assert_match(/data-turbo-frame="_top"/, html)
  end

  test "channel_mention with an unnamed private channel renders an unlinked private chip" do
    @channels = Fd::ChannelNames.new({}, Set["C0SECRET00"])

    html = channel_mention("C0SECRET00")

    assert_equal %(<span class="mention mention-private">#private-channel</span>),
      html
  end

  test "channel_mention with an unnamed private channel ignores the inline label" do
    @channels = Fd::ChannelNames.new({}, Set["C0SECRET00"])

    html = channel_mention("C0SECRET00", "do-not-leak-this")

    assert_no_match(/do-not-leak-this/, html)
    assert_match(/#private-channel/, html)
  end

  test "channel_mention with a dm id renders the private dm chip" do
    html = channel_mention("D0BQ793DP43")

    assert_equal %(<span class="mention mention-private">private dm</span>),
      html
  end

  test "channel_mention with a group dm id renders private dm" do
    html = channel_mention("G0BQ793DP43")

    assert_match(/private dm/, html)
  end

  test "link_label of a dm permalink returns private dm" do
    assert_equal "private dm",
      link_label("https://hackclub.slack.com/archives/D0BQ793DP43/p1700000000000100")
  end

  MESSAGE_LINK = "https://hackclub.slack.com/archives/C0BE6N4G2BA/p1788739817138689".freeze

  test "link_label of a message link names its channel" do
    @channels = Fd::ChannelNames.new({ "C0BE6N4G2BA" => "shroud-logs" })

    assert_equal "message in #shroud-logs", link_label(MESSAGE_LINK)
  end

  test "link_label of a message link in an unnamed private channel hides the channel" do
    @channels = Fd::ChannelNames.new({}, Set["C0BE6N4G2BA"])

    assert_equal "message in #private-channel", link_label(MESSAGE_LINK)
  end

  test "linked turns a message link into a case link when it points at a report thread" do
    @linked_cases = { ["C0BE6N4G2BA", "1788739817.138689"] =>
      Fd::LinkedCases::Target.new(case_id: 4248, report_id: 77, root_id: 4230) }

    html = linked(MESSAGE_LINK, MESSAGE_LINK)

    assert_includes html, ">Case 4248</a>"
    assert_includes html, %(href="#{ERB::Util.html_escape(fd_case_path(4230, tab: 'report', thread: 77))}")
    assert_includes html, %(data-turbo-frame="_top")
  end

  test "linked keeps the label someone gave a message link to a case" do
    @linked_cases = { ["C0BE6N4G2BA", "1788739817.138689"] =>
      Fd::LinkedCases::Target.new(case_id: 4212, report_id: 70, root_id: 4212) }

    html = linked(MESSAGE_LINK, "#4212")

    assert_includes html, ">#4212</a>"
    assert_includes html, %(href="#{ERB::Util.html_escape(fd_case_path(4212, tab: 'report', thread: 70))}")
  end

  test "linked keeps a labelled message link outside any case on Slack" do
    html = linked(MESSAGE_LINK, "this one")

    assert_includes html, ">this one</a>"
    assert_includes html, %(href="#{MESSAGE_LINK}")
  end

  test "mention_link targets the person-drawer turbo frame" do
    html = mention_link("U08EMT46G3V")

    assert_match(/data-turbo-frame="person-drawer"/, html)
  end

  def entry_at(at, **over)
    FdHelper::ChatEntry.new({ key: "k", at: at, side: "in", kind: "them", who: "U1" }.merge(over))
  end

  test "grouped_with? is true for the same author within the window" do
    first = entry_at(Time.current)
    second = entry_at(first.at + 2.minutes)

    assert grouped_with?(second, first)
  end

  test "grouped_with? is false for the same author outside the window" do
    first = entry_at(Time.current)
    second = entry_at(first.at + 6.minutes)

    assert_not grouped_with?(second, first)
  end

  test "grouped_with? is false for different authors" do
    first = entry_at(Time.current, who: "U1")
    second = entry_at(first.at + 1.second, who: "U2")

    assert_not grouped_with?(second, first)
  end

  test "grouped_with? is false for different kinds" do
    first = entry_at(Time.current, kind: "chat")
    second = entry_at(first.at + 1.second, kind: "them")

    assert_not grouped_with?(second, first)
  end

  test "grouped_with? is false without a previous entry" do
    assert_not grouped_with?(entry_at(Time.current), nil)
  end

  test "timeline_standing returns nil for an open case" do
    assert_nil timeline_standing(make_case(opened_at: 5.days.ago, assign: "UFF2"), entries(3))
  end

  test "timeline_standing for a resolved case returns the date and resolution" do
    line = timeline_standing(
      kase(resolved_at: Time.utc(2026, 3, 4, 12), resolution: "action_taken"), entries(6)
    )
    assert_equal "Resolved 4 Mar 2026 · action taken", line,
      "resolved date includes the year"
  end

  test "timeline_standing with no entries returns No events" do
    assert_equal "No events", timeline_standing(kase, [])
  end

  test "subject_handles with one subject returns the handle" do
    assert_equal "@UAAA", subject_handles(make_case(subject: "UAAA"))
  end

  test "subject_handles with several subjects returns the first handle and other count" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "@UAAA and 1 other", subject_handles(Fd::Case.find(saved.id))

    saved.add_subject!("UCCC")
    assert_equal "@UAAA and 2 others", subject_handles(Fd::Case.find(saved.id))
  end

  test "subject_handles without a subject returns No subject" do
    assert_equal "No subject", subject_handles(make_case(subject: nil))
  end

  test "category_short of nil or blank returns n/a" do
    assert_equal "n/a", category_short(nil)
    assert_equal "n/a", category_short("")
  end

  test "category_short replaces underscores with spaces" do
    assert_equal "harassment general", category_short("harassment_general")
  end

  test "prior_phrase and prior_tone with zero priors return no priors and chip-good" do
    assert_equal "no priors", prior_phrase(0)
    assert_equal "chip-good", prior_tone(0)
  end

  test "prior_phrase and prior_tone with one prior return singular and chip-off" do
    assert_equal "1 prior", prior_phrase(1)
    assert_equal "chip-off", prior_tone(1)
  end

  test "prior_phrase and prior_tone with two or more priors return plural and chip-crit" do
    assert_equal "2 priors", prior_phrase(2)
    assert_equal "chip-crit", prior_tone(2)
    assert_equal "5 priors", prior_phrase(5)
  end

  test "prior_chip with one subject shows the prior count" do
    saved = make_case(subject: "UAAA")
    chip = prior_chip(Fd::Case.find(saved.id), { "UAAA" => 3 })
    assert_match(/3 priors/, chip)
  end

  test "prior_chip with a subject missing from the counts shows no priors" do
    saved = make_case(subject: "UAAA")
    chip = prior_chip(Fd::Case.find(saved.id), {})
    assert_match(/no priors/, chip)
  end

  test "prior_chip with several subjects returns n/a" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "n/a", prior_chip(Fd::Case.find(saved.id), { "UAAA" => 4 })
  end

  test "row_subtitle starts with the category" do
    saved = make_case(subject: "UAAA", category_key: "spam")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_match(/\Aspam/, line)
  end

  test "row_subtitle omits n/a when the category is blank" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_no_match(/n\/a/, line)
  end

  test "row_subtitle shows a member report or the opener" do
    reported_case = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: reported_case.id, is_anonymous: true,
      source_app: "relay", received_at: Time.current)
    assert_match(/a member reported it/, row_subtitle(Fd::Case.find(reported_case.id), {}))

    opened_case = make_case(subject: "UAAA", opened_by: "UOPEN")
    assert_match(/@UOPEN opened it/, strip_tags(row_subtitle(Fd::Case.find(opened_case.id), {})))
  end

  test "row_subtitle includes the thread message count" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), { saved.id => 8 })
    assert_match(/8 messages/, line)
  end

  test "row_subtitle omits the message count when zero" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_no_match(/0 messages/, line)
  end

  test "row_reporter_label with a signed report returns the reporter handle" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP", is_anonymous: false,
      source_app: "relay", received_at: Time.current)
    assert_equal "@UREP", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "row_reporter_label with an anonymous report returns Anonymous" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true,
      source_app: "relay", received_at: Time.current)
    assert_equal "Anonymous", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "row_reporter_label without a report returns the opener handle" do
    saved = make_case(subject: "UAAA", opened_by: "UOPEN")
    assert_equal "@UOPEN", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "row_reporter_label with several reports returns the first reporter and other count" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP1", is_anonymous: false,
      source_app: "relay", received_at: Time.current)
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP2", is_anonymous: false,
      source_app: "relay", received_at: Time.current)
    assert_equal "@UREP1 and 1 other", row_reporter_label(Fd::Case.find(saved.id))
  end

  def report(**attrs)
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP1", is_anonymous: false,
      source_app: "relay", received_at: 3.days.ago, **attrs)
  end

  def intake(conversation_id, author:)
    Fd::IntakeMessage.create!(conversation_id: conversation_id, channel_id: "D0REP",
      ts: "#{Time.current.to_i}.0001", direction: "inbound", author_user_id: author,
      body: "they said something", posted_at: 2.days.ago)
  end

  def conversation_for(case_report)
    Fd::IntakeConversation.create!(report_id: case_report.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 3.days.ago).id
  end

  test "chat_entries for an anonymous report sets no author id and the anonymous label" do
    case_report = report(is_anonymous: true, reporter_user_id: nil)
    message = intake(conversation_for(case_report), author: "UREP1")

    entry = chat_entries([case_report], [], [message]).first

    assert_nil entry.who, "the author id must not reach the avatar"
    assert_equal "Anonymous", entry.name
    assert_equal case_report.reporter_label(names), entry.name
  end

  test "chat_entries for an anonymous report does not resolve the name table" do
    case_report = report(is_anonymous: true, reporter_user_id: nil)
    message = intake(conversation_for(case_report), author: "UREP1")
    @names = Fd::Names.for(["UREP1"])

    entry = chat_entries([case_report], [], [message]).first

    assert_not_equal @names["UREP1"], entry.name
    assert_no_match(/UREP1/, entry.name)
  end

  test "chat_entries for a signed report sets the author id and name" do
    case_report = report
    message = intake(conversation_for(case_report), author: "UREP1")

    entry = chat_entries([case_report], [], [message]).first

    assert_equal "UREP1", entry.who
    assert_match(/UREP1/, entry.name)
  end

  def create_case_chat(**attrs)
    saved = make_case(subject: "UAAA")
    Fd::CaseChat.create!(case_id: saved.id, author_user_id: "UME", source_app: "fire_engine",
      **attrs)
  end

  test "chat_entries maps a case chat row to kind chat" do
    line = create_case_chat(body: "noted for later")
    entry = chat_entries([], [line]).first

    assert_equal "chat", entry.kind
  end

  test "chat_entries maps a case chat row with action blocks to kind action" do
    line = create_case_chat(blocks: [
      { "type" => "header", "text" => { "type" => "plain_text", "text" => "Warning" } },
      { "type" => "context", "elements" => [{ "type" => "mrkdwn", "text" => "Against <@UAAA>" }] }
    ])
    entry = chat_entries([], [line]).first

    assert_equal "action", entry.kind
  end
  def pending_outbox(case_report, body = "")
    Fd::IntakeOutbox.create!(conversation_id: conversation_for(case_report), kind: "reply",
      body: body, mode: "signed", requested_by: "UFF1",
      files: [{ "name" => "shot.png", "sha256" => "abc123" }])
  end

  test "chat_entries lists pending outbox files with the sending note" do
    case_report = report

    entry = chat_entries([case_report], [], [], [pending_outbox(case_report)]).last

    assert_equal ["shot.png"], entry.files.map(&:display_name)
    assert_equal ["sending"], entry.files.map(&:note)
    assert_not entry.files.first.stored?
    assert_not entry.files.first.image?
  end

  test "chat_entries for an outbox reply without files has no files" do
    case_report = report

    entry = chat_entries([case_report], [], [], [Fd::IntakeOutbox.create!(
      conversation_id: conversation_for(case_report), kind: "reply", body: "just words",
      mode: "signed", requested_by: "UFF1"
    )]).last

    assert_empty entry.files
  end
  def create_share(message, **attrs)
    Fd::IntakeShare.create!({ message_id: message.id, kind: "forward",
      source_channel_id: "C0LOUNGE", source_ts: "1754487721.123456",
      source_author_user_id: "UBAD", source_body: "the message they reported",
      permalink: "https://hackclub.slack.com/archives/C0LOUNGE/p1754487721123456",
      is_reachable: true }.merge(attrs))
  end

  test "chat_entries attaches a forward share to the message" do
    case_report = report
    message = intake(conversation_for(case_report), author: "UREP1")
    create_share(message)

    entry = chat_entries([case_report], [], [message]).first
    share = entry.shares.sole

    assert share.forwarded?
    assert_equal "forwarded", share.kind_label
    assert share.body?
    assert_equal "the message they reported", share.source_body
  end

  def stored_file(message, slack_file_id, name, seq:, forwarded: false)
    Fd::IntakeFileBlob.create!(sha256: "sha-#{slack_file_id}", body: "png", size_bytes: 3,
      mimetype: "image/png")
    file = Fd::IntakeFile.create!(slack_file_id: slack_file_id, name: name, mimetype: "image/png",
      fetch_state: "stored", stored_key: "sha-#{slack_file_id}", sha256: "sha-#{slack_file_id}",
      original_w: 40, original_h: 20)
    Fd::IntakeFile.connection.execute(Fd::IntakeFile.sanitize_sql([
      "INSERT INTO fd.intake_message_files (message_id, file_id, seq, forwarded) VALUES (?, ?, ?, ?)",
      message.id, file.id, seq, forwarded
    ]))
  end

  test "message partial renders forwarded files inside the citation figure" do
    case_report = report
    message = intake(conversation_for(case_report), author: "UREP1")
    create_share(message, raw: { "files" => [{ "id" => "FFWD1" }] })
    stored_file(message, "FFWD1", "theirs.png", seq: 0, forwarded: true)
    stored_file(message, "FOWN1", "mine.png", seq: 1)
    entry = chat_entries([case_report], [], [message]).first

    page = Nokogiri::HTML.fragment(render(partial: "fd/cases/message", locals: { entry: entry }))

    assert_equal ["theirs.png"], page.css("figure.cite .cite-files img").map { |img| img["alt"] }
    assert_equal ["mine.png"], page.css(".msg-files img").map { |img| img["alt"] }
  end

  test "chat_entries for an unreachable link share reports link unavailable" do
    case_report = report
    message = intake(conversation_for(case_report), author: "UREP1")
    create_share(message, kind: "link", source_body: nil, permalink: nil, is_reachable: false)

    share = chat_entries([case_report], [], [message]).first.shares.sole

    assert_not share.body?
    assert_equal "linked", share.kind_label
    assert_equal "link unavailable", share.why_not
  end

  test "chat_entries for a message without shares has no shares" do
    case_report = report
    message = intake(conversation_for(case_report), author: "UREP1")

    assert_empty chat_entries([case_report], [], [message]).first.shares
  end
  def assign_cited_words(kase, **over)
    @cited_words = { kase.id => Fd::IntakeShare::Cited.new(
      { case_id: kase.id, body: "the message they reported", kind: "forward",
        author: "UBAD", channel: "C0LOUNGE", permalink: nil }.merge(over)
    ) }
  end

  test "case_cited returns the share for a report with only a link" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: "<https://hackclub.slack.com/archives/C0L/p1|x>")
    kase = Fd::Case.find(saved.id)
    assign_cited_words(kase)

    assert_equal "the message they reported", case_cited(kase).body
    assert case_cited(kase).forwarded?
    assert_equal "forwarded", case_cited(kase).kind_label
  end

  test "case_cited returns nil for a report with its own text" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: "they keep following me")
    kase = Fd::Case.find(saved.id)
    assign_cited_words(kase)

    assert_nil case_cited(kase), "report text is not replaced by the share"
    assert_equal "they keep following me", case_words(kase)
  end

  test "case_words with an empty body and attachments returns the attachment count" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: "")
    kase = Fd::Case.find(saved.id)
    @attachment_counts = { kase.id => 9 }

    assert_equal "9 attachments", case_words(kase),
      "attachment count replaces the empty body"
  end

  test "case_words with no body and no attachments returns Empty report" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: nil)
    kase = Fd::Case.find(saved.id)

    assert_equal "Empty report", case_words(kase)
  end

  test "case_words without a report returns No report" do
    kase = Fd::Case.find(make_case(subject: "UAAA").id)

    assert_equal "No report", case_words(kase)
  end

  test "plain_text strips slack link markup" do
    assert_equal "look here", plain_text("<https://slack.com/x|look here>")
    assert_equal "https://slack.com/x", plain_text("<https://slack.com/x>")
  end

  test "plain_text with slack markup returns names symbols and emoji" do
    @names = Fd::Names.new(members: { "U0123ABCD" => Struct.new(:name).new("Pat") })
    @channels = Fd::ChannelNames.new({ "C0123ABCD" => "lounge" })
    Fd::SlackUsergroup.create!(usergroup_id: "S0123ABCD", handle: "fire-department")

    assert_equal "Complaint about @Pat in #lounge: nobody asked &amp; kept going 💀 cc @fire-department",
      plain_text("Complaint about <@U0123ABCD> in <#C0123ABCD>:\n&gt; nobody asked &amp; kept going " \
                 ":skull:\ncc <!subteam^S0123ABCD>")
  end

  test "plain_text with an unknown user id wraps it for the client name lookup" do
    assert_equal %(hi <span data-cachet-name="U0123ABCD">@U0123ABCD</span>), plain_text("hi <@U0123ABCD>")
  end

  def rooted_case(body:)
    saved = make_case(subject: nil, opened_by: "UOPEN", card_channel_id: "C0FIRE",
      card_thread_ts: "1792813878.276269")
    Fd::CaseChat.create!(case_id: saved.id, author_user_id: "UFF", body: body, source_app: "nemo",
      channel_id: "C0FIRE", ts: "1792813878.276269")
    kase = Fd::Case.find(saved.id)
    @case_roots = Fd::QueuePreviews.for([kase]).roots
    kase
  end

  test "case_words without a report returns the root message text" do
    kase = rooted_case(body: "got bot-kicked from <#C0123ABCD>")
    @channels = Fd::ChannelNames.new({ "C0123ABCD" => "lounge" })

    assert_equal "got bot-kicked from #lounge", case_words(kase)
  end

  test "row_reporter_label without a report returns the root message author" do
    kase = rooted_case(body: "got bot-kicked")

    assert_equal "@UFF", row_reporter_label(kase)
  end
  def build_guard(**over)
    Fd::MemberGuard.new({ kind: "shush", subject_id: "USUB", opened_by: "UMOD",
                          reason: "being awful" }.merge(over))
  end

  test "guard_standing_where distinguishes no case from this case and another case" do
    assert_equal "on no case", guard_standing_where(build_guard(case_id: nil), 1)
    assert_equal "on this case", guard_standing_where(build_guard(case_id: 1), 1)
    assert_equal "on case 9", guard_standing_where(build_guard(case_id: 9), 1)
  end

  test "guard_line appends on no case only for a guard without a case id" do
    assert_equal "Shush, on no case", guard_line(build_guard)
    assert_equal "Shush", guard_line(build_guard(case_id: 1))
  end

  test "clock_stamp renders the time in the current zone with a UTC title" do
    at = Time.utc(2026, 10, 12, 14, 5)

    stamp = Time.use_zone("America/New_York") { clock_stamp(at) }

    assert_match(%r{<time datetime="2026-10-12T10:05:00-04:00" title="12 Oct 2026 14:05 UTC">12 Oct 10:05</time>}, stamp)
  end

  def next_year_expiry = Time.zone.local(Date.current.year + 1, 10, 15, 12)

  test "thread_lock_note with expiry in next year includes year" do
    note = thread_lock_note(build_guard(case_id: 1, expires_at: next_year_expiry), 1)

    assert_includes note, "lifts 15 Oct #{Date.current.year + 1}"
  end

  test "guard_option_note with expiry in next year includes year" do
    note = guard_option_note(build_guard(case_id: 1, expires_at: next_year_expiry), 1)

    assert_includes note, "until 15 Oct #{Date.current.year + 1}"
  end

  test "guard_footnote with opened_at in past year includes year" do
    guard = build_guard(opened_at: Time.zone.local(Date.current.year - 1, 3, 3, 12),
      expires_at: next_year_expiry, enforced_by: "nemo", enforcement_status: "pending")

    footnote = guard_footnote(guard, Fd::Names.none)

    assert_includes footnote, "since 3 Mar #{Date.current.year - 1}"
    assert_includes footnote, "until 15 Oct #{Date.current.year + 1}"
  end
end
