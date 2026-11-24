require "test_helper"

class Fd::MemberTimelineTest < ActiveSupport::TestCase
  SUBJECT = "UPRIOR".freeze

  def entries(only: "all")
    Fd::MemberTimeline.for(Fd::MemberRecord.new(SUBJECT), only: only)
  end

  def act_on(kase, at: 1.day.ago, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: SUBJECT,
                         decided_by: "UFF1", performed_by: "UFF1", performed_at: at }.merge(attrs))
  end

  test "case about the subject yields an own cases entry with the resolution state" do
    make_case(subject: SUBJECT, opened_at: 5.days.ago, resolved_at: 1.day.ago,
      resolution: "action_taken", category_key: "spam")
    entry = entries.sole

    assert_match(/\ACase \d+ opened\z/, entry.title)
    assert_equal "cases", entry.kind
    assert_equal "own", entry.mark
    assert_equal "action taken", entry.state
    assert_match(/spam/, entry.detail)
  end

  test "unresolved case entry has state open" do
    make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_equal "open", entries.sole.state
  end

  test "case with the subject as reporter yields an in entry marked logged in" do
    reporter_case = make_case(subject: "USOMEBODY", opened_at: 3.days.ago, category_key: "bullying")
    reporter_case.participants.create!(user_id: SUBJECT, role: "reporter")

    entry = entries.sole
    assert_equal "cases", entry.kind
    assert_equal "in", entry.mark, "mark differs from a case about the subject"
    assert_equal "logged in", entry.state
    assert_match(/not the subject/, entry.detail)
  end

  test "action on the subject yields an actions entry naming the case and actor" do
    kase = make_case(subject: SUBJECT, opened_at: 5.days.ago)
    act_on kase, at: 2.days.ago

    action = entries.find { |entry| entry.kind == "actions" }
    assert_equal "Warning", action.title
    assert_match(/case #{kase.id}/, action.detail)
    assert_match(/by @UFF1/, action.detail)
    assert_no_match(/performed by/, action.detail, "detail names the actor once")
  end

  test "reversed action yields an entry at reversed_at with the reversal reason" do
    kase = make_case(subject: SUBJECT, opened_at: 9.days.ago)
    act_on kase, at: 8.days.ago, reversed_at: 2.days.ago, reversed_by: "UFF2",
      reversal_reason: "appeal upheld"

    reversal = entries.find { |entry| entry.title.end_with?("reversed") }
    assert_in_delta 2.days.ago.to_i, reversal.at.to_i, 5
    assert_equal "reversed", reversal.state
    assert_match(/appeal upheld/, reversal.detail)
  end

  def create_guard(kind: "shush", at: 3.days.ago, **attrs)
    Fd::MemberGuard.create!({ kind: kind, subject_id: SUBJECT, opened_by: "UFF1",
                              reason: "flooding the channel", opened_at: at,
                              enforced_by: "nemo", enforcement_status: "pending" }.merge(attrs))
  end

  test "guard without a case yields an actions entry with no case_id" do
    create_guard(expires_at: 2.days.from_now)
    entry = entries(only: "actions").sole

    assert_equal "Shush", entry.title
    assert_equal "act", entry.mark
    assert_nil entry.case_id, "case_id is nil without a case"
    assert_match(/on no case/, entry.detail)
    assert_match(/by @UFF1/, entry.detail)
    assert_match(/flooding the channel/, entry.detail)
    assert_nil entry.state, "state is nil for an unlifted guard"
  end

  test "lift-only deactivation without a case yields no entries" do
    guard = create_guard(kind: "deactivation", reason: "Deactivated outside Nemo", lift_only: true,
      enforcement_status: "held")
    guard.update!(state: "lifting", lifted_by: "UFF2", lift_reason: "appeal accepted")

    assert_empty entries(only: "actions")
  end

  test "channel ban guard without a case names the channel in detail" do
    create_guard(kind: "channel_ban", channel_id: "C1LOUNGE", expires_at: 2.days.from_now)

    assert_match(/in C1LOUNGE/, entries(only: "actions").sole.detail)
  end

  test "guard_detail with expiry in next year includes year" do
    expiry = Time.zone.local(Date.current.year + 1, 10, 15, 12)
    create_guard(expires_at: expiry)

    assert_match(/lifts 15 Oct #{expiry.year}/, entries(only: "actions").sole.detail)
  end

  test "action_detail with expiry in next year includes year" do
    kase = make_case(subject: SUBJECT, opened_at: 5.days.ago)
    expiry = Time.zone.local(Date.current.year + 1, 10, 15, 12)
    act_on kase, at: 2.days.ago, type_key: "shush", expires_at: expiry

    action = entries.find { |entry| entry.kind == "actions" }
    assert_match(/lifts 15 Oct #{expiry.year}/, action.detail)
  end

  test "lifted guard without a case yields a reversal entry at lifted_at" do
    guard = create_guard(at: 9.days.ago)
    guard.update!(state: "lifted", lifted_at: 2.days.ago, lifted_by: "UFF2",
      lift_reason: "they sorted it out")

    lift_entry, guard_entry = entries(only: "actions")
    assert_equal "Shush lifted", lift_entry.title
    assert_in_delta 2.days.ago.to_i, lift_entry.at.to_i, 5
    assert_equal "reversal", lift_entry.word
    assert_match(/they sorted it out/, lift_entry.detail)
    assert_match(/by @UFF2/, lift_entry.detail)
    assert_equal "reversed", guard_entry.state, "the guard entry state is reversed"
  end

  test "guard with a case_id yields no actions entry" do
    kase = make_case(subject: SUBJECT, opened_at: 5.days.ago)
    create_guard(case_id: kase.id, expires_at: 2.days.from_now)

    assert_empty entries(only: "actions")
  end

  test "guard for another subject is excluded" do
    create_guard(subject_id: "USOMEBODY", expires_at: 2.days.from_now)

    assert_empty entries(only: "actions")
  end

  test "entries are ordered newest first across cases and actions" do
    kase = make_case(subject: SUBJECT, opened_at: 10.days.ago)
    act_on kase, at: 3.days.ago
    make_case(subject: SUBJECT, opened_at: 6.days.ago)

    stamps = entries.map(&:at)
    assert_equal stamps.sort.reverse, stamps
  end

  test "only filter limits entries to the requested kind" do
    kase = make_case(subject: SUBJECT, opened_at: 10.days.ago)
    act_on kase, at: 3.days.ago
    other = make_case(subject: "USOMEBODY", opened_at: 8.days.ago)
    other.participants.create!(user_id: SUBJECT, role: "reporter")

    assert_equal 3, entries.size
    assert_equal ["cases"], entries(only: "cases").map(&:kind).uniq
    assert_equal 2, entries(only: "cases").size, "one case about the subject and one as reporter"
    assert_equal ["actions"], entries(only: "actions").map(&:kind).uniq
  end

  test "unknown only value returns all entries" do
    make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_equal 1, entries(only: "nonsense").size
  end

  test "case with several subjects lists the others in detail" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    kase.add_subject!("UOTHER")

    assert_match(/with @UOTHER/, entries.sole.detail)
  end

  test "case entry detail reads unassigned then assigned to the assignee after assign!" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_match(/unassigned/, entries.sole.detail)

    kase.assign!("UFF1")
    assert_match(/assigned to @UFF1/, entries.sole.detail)
  end

  test "MemberTimeline.for returns empty for a user with no records" do
    assert_empty Fd::MemberTimeline.for(Fd::MemberRecord.new("UNOBODY"))
  end

  def note_about(user_id = SUBJECT, body: "a soft word early goes further", **attrs)
    Fd::Note.create!({ subject_user_id: user_id, body: body, author: "UFF1" }.merge(attrs))
  end

  test "KINDS keys are all cases actions notes in order" do
    assert_equal %w[all cases actions notes], Fd::MemberTimeline::KINDS.keys
  end

  test "standing note yields a notes entry with body and author state" do
    note_about
    entry = entries(only: "notes").sole

    assert_equal "Note", entry.title
    assert_equal "note", entry.mark
    assert_equal "a soft word early goes further", entry.body
    assert_nil entry.case_id, "case_id is nil for a standing note"
    assert_equal "@UFF1", entry.state, "state is the author handle"
  end

  test "note for another subject is excluded" do
    note_about("USOMEBODY")
    assert_empty entries(only: "notes")
  end

  test "case note is excluded from the notes entries" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "case note", author: "UFF1")

    assert_empty entries(only: "notes")
  end

  test "deleted note is excluded from the notes entries" do
    note_about.update!(deleted_at: Time.current, deleted_by: "UFF1")
    assert_empty entries(only: "notes")
  end

  test "entries include notes with cases and actions ordered newest first" do
    kase = make_case(subject: SUBJECT, opened_at: 5.days.ago)
    act_on kase, at: 3.days.ago
    note_about(created_at: 1.day.ago)

    rows = entries
    assert_equal 3, rows.size
    assert_equal %w[notes actions cases], rows.map(&:kind)
  end
end
