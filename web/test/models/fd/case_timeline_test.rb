require "test_helper"

class Fd::CaseTimelineTest < ActiveSupport::TestCase
  OPENED = Time.utc(2026, 3, 1, 9, 0)

  def kase(**attrs)
    Fd::Case.new({ id: 1, opened_by: "UFF1", opened_at: OPENED }.merge(attrs))
  end

  def subject(user_id = "USUB")
    Fd::CaseParticipant.new(user_id: user_id, role: "subject")
  end

  def report(**attrs)
    Fd::CaseReport.new({
      received_at: OPENED - 10.minutes, is_anonymous: true, source_app: "shroud"
    }.merge(attrs))
  end

  def action(**attrs)
    Fd::Action.new({
      type_key: "warning", target_user_id: "USUB", decided_by: "UFF1", performed_by: "UFF1",
      performed_at: OPENED + 1.hour, source_app: "fire_engine", details: {}
    }.merge(attrs))
  end

  def note(**attrs)
    Fd::Note.new({ body: "spoke to them", author: "UFF1", created_at: OPENED + 30.minutes }.merge(attrs))
  end

  def build(kase, reports: [], actions: [], notes: [], participants: [subject])
    Fd::CaseTimeline.for(kase, reports:, actions:, notes:, participants:)
  end

  test "entries run oldest first regardless of which table they came from" do
    entries = build(
      kase(claimed_by: "UFF1", claimed_at: OPENED + 20.minutes),
      reports: [report],
      actions: [action],
      notes: [note],
    )
    assert_equal ["Report received", "Case opened", "Assigned", "Note added", "Warning"],
      entries.map(&:title)
    assert_equal entries.map(&:at).sort, entries.map(&:at)
  end

  test "an anonymous report is chipped and never names anybody" do
    entry = build(kase, reports: [report(body: "they keep at it")]).first
    assert_equal ["anonymous"], entry.chips
    assert_equal "they keep at it", entry.said
    assert_no_match(/@/, entry.detail)
  end

  test "an identified reporter who was also involved says so once" do
    person = Fd::CaseParticipant.new(user_id: "UT", role: "involved")
    entry = build(
      kase,
      reports: [report(is_anonymous: false, reporter_user_id: "UT")],
      participants: [person],
    ).first
    assert_equal "from @UT, who was involved · via shroud · no reply yet · told the outcome: not yet",
      entry.detail
  end

  test "reply latency is stated in words rather than seconds" do
    row = report(is_anonymous: false, reporter_user_id: "UR",
      first_replied_at: OPENED - 10.minutes + 12.minutes)
    assert_includes build(kase, reports: [row]).first.detail, "replied in 12 minutes"
  end

  test "assignment is measured from opening" do
    entry = build(kase(claimed_by: "UFF2", claimed_at: OPENED + 28.minutes))
      .find { |e| e.title == "Assigned" }
    assert_equal "@UFF2 · 28 minutes after opening", entry.detail
  end

  test "an action performed by the bot names the bot, not a handle" do
    entry = build(kase, actions: [action(type_key: "locked_thread", performed_by: "UMNEMOSYNE",
      details: { "channel_id" => "C123" })]).last
    assert_equal "Locked thread", entry.title
    assert_equal "decided by @UFF1 · performed by Mnemosyne · in C123", entry.detail
  end

  test "an action on somebody other than the subject says who" do
    entry = build(kase, actions: [action(target_user_id: "UOTHER")]).last
    assert_match(/\Aon @UOTHER · /, entry.detail)
  end

  test "an action against the subject does not repeat the subject" do
    assert_no_match(/on @USUB/, build(kase, actions: [action]).last.detail)
  end

  test "a reversal is its own entry at its own time" do
    row = action(reversed_at: OPENED + 2.days, reversed_by: "UFF2", reversal_reason: "appeal upheld")
    entries = build(kase, actions: [row])
    assert_equal ["Case opened", "Warning", "Warning reversed"], entries.map(&:title)
    assert_equal "by @UFF2 · appeal upheld", entries.last.detail
    assert_equal OPENED + 2.days, entries.last.at
  end

  test "an expiring action carries its date as a chip" do
    entry = build(kase, actions: [action(type_key: "shush", expires_at: OPENED + 7.days)]).last
    assert_equal ["expires Mar 8"], entry.chips
  end

  test "a standing note is marked as being about the member" do
    entry = build(kase, notes: [note(subject_user_id: "USUB", body: "escalates in public")])
      .find { |e| e.title == "Note added" }
    assert_equal ["about @USUB"], entry.chips
    assert_equal "escalates in public", entry.said
    assert_equal "by @UFF1", entry.detail
  end

  test "a case note carries no chip" do
    entry = build(kase, notes: [note(case_id: 1)]).find { |e| e.title == "Note added" }
    assert_empty entry.chips
  end

  test "resolution quotes what the member was told and flags when they were told nothing" do
    told = build(kase(resolved_at: OPENED + 1.day, resolution: "action_taken",
      member_note: "we spoke to them")).last
    assert_equal "we spoke to them", told.said
    assert_no_match(/not told/, told.detail)

    silent = build(kase(resolved_at: OPENED + 1.day, resolution: "no_action")).last
    assert_match(/the member was not told/, silent.detail)
  end

  test "a case with nothing attached still records that it was opened" do
    entries = build(kase)
    assert_equal ["Case opened"], entries.map(&:title)
    assert_equal "by @UFF1", entries.first.detail
  end
end
