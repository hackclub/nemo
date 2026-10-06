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

  test "a channel mention opens the fire-engine channel page" do
    html = channel_mention("C0BE6N4G2BA")

    assert_match(%r{href="/fd/channels/C0BE6N4G2BA"}, html)
    assert_match(/data-turbo-frame="_top"/, html)
  end

  test "a private channel we cannot name is a generic, unlinked chip" do
    @channels = Fd::ChannelNames.new({}, Set["C0SECRET00"])

    html = channel_mention("C0SECRET00")

    assert_equal %(<span class="mention mention-private" title="C0SECRET00">#private-channel</span>),
      html
  end

  test "a private channel we cannot name stays generic even with an inline label" do
    @channels = Fd::ChannelNames.new({}, Set["C0SECRET00"])

    html = channel_mention("C0SECRET00", "do-not-leak-this")

    assert_no_match(/do-not-leak-this/, html)
    assert_match(/#private-channel/, html)
  end

  test "a link shared from a dm never shows the raw channel id" do
    html = channel_mention("D0BQ793DP43")

    assert_equal %(<span class="mention mention-private" title="D0BQ793DP43">private dm</span>),
      html
  end

  test "a link shared from a group dm reads the same as a plain dm" do
    html = channel_mention("G0BQ793DP43")

    assert_match(/private dm/, html)
  end

  test "a bare permalink pasted from a dm labels itself, not the raw id" do
    assert_equal "private dm",
      link_label("https://hackclub.slack.com/archives/D0BQ793DP43/p1700000000000100")
  end

  test "a user mention does not ask the chat log to swap itself" do
    html = mention_link("U08EMT46G3V")

    assert_match(/data-turbo-frame="person-drawer"/, html)
  end

  def entry_at(at, **over)
    FdHelper::ChatEntry.new({ key: "k", at: at, side: "in", kind: "them", who: "U1" }.merge(over))
  end

  test "the same author back to back within the window groups" do
    first = entry_at(Time.current)
    second = entry_at(first.at + 2.minutes)

    assert grouped_with?(second, first)
  end

  test "the same author outside the window does not group" do
    first = entry_at(Time.current)
    second = entry_at(first.at + 6.minutes)

    assert_not grouped_with?(second, first)
  end

  test "a different author never groups, however close" do
    first = entry_at(Time.current, who: "U1")
    second = entry_at(first.at + 1.second, who: "U2")

    assert_not grouped_with?(second, first)
  end

  test "the same author but a different kind never groups" do
    first = entry_at(Time.current, kind: "chat")
    second = entry_at(first.at + 1.second, kind: "them")

    assert_not grouped_with?(second, first)
  end

  test "there is nothing before the first entry" do
    assert_not grouped_with?(entry_at(Time.current), nil)
  end

  test "an open case adds no standing line under its timeline" do
    assert_nil timeline_standing(make_case(opened_at: 5.days.ago, assign: "UFF2"), entries(3))
  end

  test "a resolved case states its outcome" do
    line = timeline_standing(
      kase(resolved_at: Time.utc(2026, 3, 4, 12), resolution: "action_taken"), entries(6)
    )
    assert_equal "Resolved 4 Mar 2026 as action taken.", line,
      "a date without its year reads the same whether it was this March or three Marches ago"
  end

  test "an empty timeline says nothing has happened" do
    assert_equal "Nothing has happened on this case yet.", timeline_standing(kase, [])
  end

  test "one subject reads as a handle" do
    assert_equal "@UAAA", subject_handles(make_case(subject: "UAAA"))
  end

  test "several subjects name the first and count the rest" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "@UAAA and 1 other", subject_handles(Fd::Case.find(saved.id))

    saved.add_subject!("UCCC")
    assert_equal "@UAAA and 2 others", subject_handles(Fd::Case.find(saved.id))
  end

  test "a case about nobody says so rather than naming an empty handle" do
    assert_equal "no subject set", subject_handles(make_case(subject: nil))
  end

  test "a blank category is n/a, not a bare key" do
    assert_equal "n/a", category_short(nil)
    assert_equal "n/a", category_short("")
  end

  test "a category key reads with spaces, not underscores" do
    assert_equal "harassment general", category_short("harassment_general")
  end

  test "zero priors reads as never reported, not zero" do
    assert_equal "never reported before", prior_phrase(0)
    assert_equal "chip-good", prior_tone(0)
  end

  test "one prior is singular" do
    assert_equal "1 prior", prior_phrase(1)
    assert_equal "chip-off", prior_tone(1)
  end

  test "two or expand priors are plural and read as a warning" do
    assert_equal "2 priors", prior_phrase(2)
    assert_equal "chip-crit", prior_tone(2)
    assert_equal "5 priors", prior_phrase(5)
  end

  test "a case with one subject shows their prior count" do
    saved = make_case(subject: "UAAA")
    chip = prior_chip(Fd::Case.find(saved.id), { "UAAA" => 3 })
    assert_match(/3 priors/, chip)
  end

  test "a subject missing from the prior count reads as never reported" do
    saved = make_case(subject: "UAAA")
    chip = prior_chip(Fd::Case.find(saved.id), {})
    assert_match(/never reported before/, chip)
  end

  test "a case with no single subject has no prior chip to show" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "n/a", prior_chip(Fd::Case.find(saved.id), { "UAAA" => 4 })
  end

  test "the row subtitle folds the category in front of who raised it" do
    saved = make_case(subject: "UAAA", category_key: "spam")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_match(/\Aspam/, line)
  end

  test "a blank category does not leave a stray n/a in the subtitle" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_no_match(/n\/a/, line)
  end

  test "the subtitle says who raised it, reporter or opener" do
    reported = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: reported.id, is_anonymous: true,
      source_app: "relay", received_at: Time.current)
    assert_match(/a member reported it/, row_subtitle(Fd::Case.find(reported.id), {}))

    opened = make_case(subject: "UAAA", opened_by: "UOPEN")
    assert_match(/@UOPEN opened it/, row_subtitle(Fd::Case.find(opened.id), {}))
  end

  test "a case with thread messages counts them in the subtitle" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), { saved.id => 8 })
    assert_match(/8 messages/, line)
  end

  test "a case with no thread messages does not print a zero" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_no_match(/0 messages/, line)
  end

  test "the drawer still names the reporter when a report is on file" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP", is_anonymous: false,
      source_app: "relay", received_at: Time.current)
    assert_equal "@UREP", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "an anonymous report reads as anonymous, not by the missing name" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true,
      source_app: "relay", received_at: Time.current)
    assert_equal "Anonymous", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "a case with no report at all names who opened it directly" do
    saved = make_case(subject: "UAAA", opened_by: "UOPEN")
    assert_equal "@UOPEN", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "several reports name the first reporter and count the rest" do
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

  def conversation_for(filed)
    Fd::IntakeConversation.create!(report_id: filed.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 3.days.ago).id
  end

  test "an anonymous reporter is not named in their own transcript" do
    filed = report(is_anonymous: true, reporter_user_id: nil)
    message = intake(conversation_for(filed), author: "UREP1")

    entry = chat_entries([filed], [], [message]).first

    assert_nil entry.who, "the author id must not reach the avatar"
    assert_equal "Anonymous", entry.name
    assert_equal filed.reporter_label(names), entry.name
  end

  test "an anonymous transcript never resolves the author against the name table" do
    filed = report(is_anonymous: true, reporter_user_id: nil)
    message = intake(conversation_for(filed), author: "UREP1")
    @names = Fd::Names.for(["UREP1"])

    entry = chat_entries([filed], [], [message]).first

    assert_not_equal @names["UREP1"], entry.name
    assert_no_match(/UREP1/, entry.name)
  end

  test "a signed reporter is still named in their transcript" do
    filed = report
    message = intake(conversation_for(filed), author: "UREP1")

    entry = chat_entries([filed], [], [message]).first

    assert_equal "UREP1", entry.who
    assert_match(/UREP1/, entry.name)
  end

  def logged_action(**attrs)
    saved = make_case(subject: "UAAA")
    Fd::CaseChat.create!(case_id: saved.id, author_user_id: "UME", source_app: "fire_engine",
      **attrs)
  end

  test "an ordinary chat note reads as plain chat" do
    line = logged_action(body: "noted for later")
    entry = chat_entries([], [line]).first

    assert_equal "chat", entry.kind
  end

  test "a logged action's echo reads as its own kind, not plain chat" do
    line = logged_action(blocks: [
      { "type" => "header", "text" => { "type" => "plain_text", "text" => "Warning" } },
      { "type" => "context", "elements" => [{ "type" => "mrkdwn", "text" => "Against <@UAAA>" }] }
    ])
    entry = chat_entries([], [line]).first

    assert_equal "action", entry.kind
  end
  def waiting(filed, body = "")
    Fd::IntakeOutbox.create!(conversation_id: conversation_for(filed), kind: "reply",
      body: body, mode: "signed", requested_by: "UFF1",
      files: [{ "name" => "shot.png", "sha256" => "abc123" }])
  end

  test "a reply still on its way shows what it carries, as the reporter's does" do
    filed = report

    entry = chat_entries([filed], [], [], [waiting(filed)]).last

    assert_equal ["shot.png"], entry.files.map(&:shown_name)
    assert_equal ["sending"], entry.files.map(&:note)
    assert_not entry.files.first.kept?
    assert_not entry.files.first.image?
  end

  test "a reply carrying nothing has no file chips to show" do
    filed = report

    entry = chat_entries([filed], [], [], [Fd::IntakeOutbox.create!(
      conversation_id: conversation_for(filed), kind: "reply", body: "just words",
      mode: "signed", requested_by: "UFF1"
    )]).last

    assert_empty entry.files
  end
  def cited(message, **attrs)
    Fd::IntakeShare.create!({ message_id: message.id, kind: "forward",
      source_channel_id: "C0LOUNGE", source_ts: "1754487721.123456",
      source_author_user_id: "UBAD", source_body: "the message they reported",
      permalink: "https://hackclub.slack.com/archives/C0LOUNGE/p1754487721123456",
      is_reachable: true }.merge(attrs))
  end

  test "a forwarded message is cited under the words it arrived with" do
    filed = report
    message = intake(conversation_for(filed), author: "UREP1")
    cited(message)

    entry = chat_entries([filed], [], [message]).first
    share = entry.shares.sole

    assert share.forwarded?
    assert_equal "forwarded", share.word
    assert share.body?
    assert_equal "the message they reported", share.source_body
  end

  test "a link nobody could open says so rather than quoting nothing" do
    filed = report
    message = intake(conversation_for(filed), author: "UREP1")
    cited(message, kind: "link", source_body: nil, permalink: nil, is_reachable: false)

    share = chat_entries([filed], [], [message]).first.shares.sole

    assert_not share.body?
    assert_equal "linked", share.word
    assert_equal "a link we could not open", share.why_not
  end

  test "a message with nothing cited carries no citation blocks" do
    filed = report
    message = intake(conversation_for(filed), author: "UREP1")

    assert_empty chat_entries([filed], [], [message]).first.shares
  end
  def listed(kase, **over)
    @cited_words = { kase.id => Fd::IntakeShare::Cited.new(
      { case_id: kase.id, body: "the message they reported", kind: "forward",
        author: "UBAD", channel: "C0LOUNGE", permalink: nil }.merge(over)
    ) }
  end

  test "a case whose report is only a link is summed up by what it points at" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: "<https://hackclub.slack.com/archives/C0L/p1|x>")
    kase = Fd::Case.find(saved.id)
    listed(kase)

    assert_equal "the message they reported", case_cited(kase).body
    assert case_cited(kase).forwarded?
    assert_equal "forwarded", case_cited(kase).word
  end

  test "a report with words of its own is not replaced by what it links to" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: "they keep following me")
    kase = Fd::Case.find(saved.id)
    listed(kase)

    assert_nil case_cited(kase), "their own words win"
    assert_equal "they keep following me", case_words(kase)
  end

  test "a report whose words are empty but carries files is summed up by the files" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: "")
    kase = Fd::Case.find(saved.id)
    @held_counts = { kase.id => 9 }

    assert_equal "9 attachments", case_words(kase),
      "the reporter typed nothing, they did not send nothing"
  end

  test "a report with neither words nor anything attached says only that" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true, source_app: "relay",
      received_at: Time.current, body: nil)
    kase = Fd::Case.find(saved.id)

    assert_equal "a report with nothing in it", case_words(kase)
  end

  test "a case with no report at all still says so" do
    kase = Fd::Case.find(make_case(subject: "UAAA").id)

    assert_equal "no report on file", case_words(kase)
  end

  test "slack link markup is never shown raw in the list" do
    assert_equal "look here", plain_text("<https://slack.com/x|look here>")
    assert_equal "https://slack.com/x", plain_text("<https://slack.com/x>")
  end
  def held(**over)
    Fd::MemberGuard.new({ kind: "shush", subject_id: "USUB", opened_by: "UMOD",
                          reason: "being awful" }.merge(over))
  end

  test "a guard says which case it sits on, or that it sits on none" do
    assert_equal "on no case", guard_standing_where(held(case_id: nil), 1)
    assert_equal "on this case", guard_standing_where(held(case_id: 1), 1)
    assert_equal "on case 9", guard_standing_where(held(case_id: 9), 1)
  end

  test "a workspace guard names no channel" do
    assert_equal "Shush, on no case", guard_held_line(held)
    assert_equal "Shush", guard_held_line(held(case_id: 1))
  end
end
