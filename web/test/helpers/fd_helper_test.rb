require "test_helper"

class FdHelperTest < ActionView::TestCase
  include FdHelper

  def kase(**attrs)
    make_case(opened_at: 5.days.ago, **attrs)
  end

  def entries(count)
    Array.new(count) { Fd::CaseTimeline::Entry.new(at: Time.current, title: "x") }
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

  test "two or more priors are plural and read as a warning" do
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

  test "several subjects are named on the row, not counted in the subtitle" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_match(/@UAAA and 1 other/, row_subject_label(Fd::Case.find(saved.id)))
  end

  test "no subject yet says so plainly, not as a bare n/a" do
    saved = make_case(subject: nil)
    assert_equal "nobody identified yet", row_subject_label(Fd::Case.find(saved.id))
  end

  test "the subtitle says who raised it, reporter or opener" do
    reported = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: reported.id, is_anonymous: true,
      source_app: "shroud", received_at: Time.current)
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
      source_app: "shroud", received_at: Time.current)
    assert_equal "@UREP", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "an anonymous report reads as anonymous, not by the missing name" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true,
      source_app: "shroud", received_at: Time.current)
    assert_equal "anonymous", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "a case with no report at all names who opened it directly" do
    saved = make_case(subject: "UAAA", opened_by: "UOPEN")
    assert_equal "@UOPEN", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "several reports name the first reporter and count the rest" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP1", is_anonymous: false,
      source_app: "shroud", received_at: Time.current)
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP2", is_anonymous: false,
      source_app: "shroud", received_at: Time.current)
    assert_equal "@UREP1 and 1 other", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "a finished case is asked for nothing" do
    assert_nil still_needed([])
  end

  test "what is still needed is counted, not left to guess" do
    assert_equal "One thing before this can close", still_needed([:subject])
    assert_equal "Two things before this can close", still_needed([:subject, :evidence])
    assert_equal "Three things before this can close",
      still_needed([:subject, :violation, :evidence])
  end

  def report(**attrs)
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP1", is_anonymous: false,
      source_app: "shroud", received_at: 3.days.ago, **attrs)
  end

  test "an unanswered report says how long the reporter has been waiting" do
    state, line = report_reply_state(report)
    assert_equal :waiting, state
    assert_equal "no reply to the reporter yet, 3d", line
  end

  test "an answered report gives the date, not the wait" do
    state, line = report_reply_state(report(first_replied_at: Time.utc(2026, 3, 4, 12)))
    assert_equal :replied, state
    assert_equal "replied 4 Mar 2026", line
  end

  test "a closed report names who told the reporter the outcome" do
    said = report(first_replied_at: 2.days.ago, closed_at: Time.utc(2026, 3, 5, 12),
      closed_by: "USTAFF")
    state, line = report_reply_state(said)
    assert_equal :told, state
    assert_equal "told the outcome 5 Mar by @USTAFF", line
  end

  def intake(conversation_id, author:)
    Fd::IntakeMessage.create!(conversation_id: conversation_id, channel_id: "D0REP",
      ts: "#{Time.current.to_i}.0001", direction: "inbound", author_user_id: author,
      body: "they said something", posted_at: 2.days.ago)
  end

  def conversation_for(said)
    Fd::IntakeConversation.create!(report_id: said.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 3.days.ago).id
  end

  test "an anonymous reporter is not named in their own transcript" do
    said = report(is_anonymous: true, reporter_user_id: nil)
    message = intake(conversation_for(said), author: "UREP1")

    entry = chat_entries([said], [], [message]).first

    assert_nil entry.who, "the author id must not reach the avatar"
    assert_equal "anonymous", entry.name
    assert_equal said.reporter_label(names), entry.name
  end

  test "an anonymous transcript never resolves the author against the name table" do
    said = report(is_anonymous: true, reporter_user_id: nil)
    message = intake(conversation_for(said), author: "UREP1")
    @names = Fd::Names.for(["UREP1"])

    entry = chat_entries([said], [], [message]).first

    assert_not_equal @names["UREP1"], entry.name
    assert_no_match(/UREP1/, entry.name)
  end

  test "a signed reporter is still named in their transcript" do
    said = report
    message = intake(conversation_for(said), author: "UREP1")

    entry = chat_entries([said], [], [message]).first

    assert_equal "UREP1", entry.who
    assert_match(/UREP1/, entry.name)
  end
end
