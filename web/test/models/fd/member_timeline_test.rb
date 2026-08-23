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

  test "a case they were the subject of reads as opened, with its outcome" do
    make_case(subject: SUBJECT, opened_at: 5.days.ago, resolved_at: 1.day.ago,
      resolution: "action_taken", category_key: "spam")
    entry = entries.sole

    assert_match(/\ACase \d+ opened\z/, entry.title)
    assert_equal "cases", entry.kind
    assert_equal "own", entry.mark
    assert_equal "action taken", entry.state
    assert_match(/spam/, entry.detail)
  end

  test "an open case says open rather than naming a resolution" do
    make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_equal "open", entries.sole.state
  end

  test "a case they were only logged in carries their role and their reason" do
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago, category_key: "bullying")
    theirs.participants.create!(user_id: SUBJECT, role: "involved", detail: "it was aimed at them")

    entry = entries.sole
    assert_equal "cases", entry.kind
    assert_equal "in", entry.mark, "the mark still tells it from a case about them"
    assert_equal "logged in", entry.state
    assert_match(/it was aimed at them/, entry.detail)
    assert_match(/they were not the subject/, entry.detail)
  end

  test "an action against them is its own entry, naming the case it came from" do
    kase = make_case(subject: SUBJECT, opened_at: 5.days.ago)
    act_on kase, at: 2.days.ago

    action = entries.find { |entry| entry.kind == "actions" }
    assert_equal "Warning", action.title
    assert_match(/case #{kase.id}/, action.detail)
    assert_match(/decided by/, action.detail)
  end

  test "a reversal is its own entry, at the moment it was undone" do
    kase = make_case(subject: SUBJECT, opened_at: 9.days.ago)
    act_on kase, at: 8.days.ago, reversed_at: 2.days.ago, reversed_by: "UFF2",
      reversal_reason: "appeal upheld"

    reversal = entries.find { |entry| entry.title.end_with?("reversed") }
    assert_equal 2.days.ago.to_i, reversal.at.to_i
    assert_equal "reversed", reversal.state
    assert_match(/appeal upheld/, reversal.detail)
  end

  test "everything is newest first, whichever table it came from" do
    kase = make_case(subject: SUBJECT, opened_at: 10.days.ago)
    act_on kase, at: 3.days.ago
    make_case(subject: SUBJECT, opened_at: 6.days.ago)

    stamps = entries.map(&:at)
    assert_equal stamps.sort.reverse, stamps
  end

  test "the filter narrows to one kind and leaves the rest out" do
    kase = make_case(subject: SUBJECT, opened_at: 10.days.ago)
    act_on kase, at: 3.days.ago
    other = make_case(subject: "USOMEBODY", opened_at: 8.days.ago)
    other.participants.create!(user_id: SUBJECT, role: "reporter")

    assert_equal 3, entries.size
    assert_equal ["cases"], entries(only: "cases").map(&:kind).uniq
    assert_equal 2, entries(only: "cases").size, "one about them, one they were logged in"
    assert_equal ["actions"], entries(only: "actions").map(&:kind).uniq
  end

  test "an unknown filter falls back to everything rather than emptying the page" do
    make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_equal 1, entries(only: "nonsense").size
  end

  test "a case about several people names the others" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    kase.add_subject!("UOTHER")

    assert_match(/with @UOTHER/, entries.sole.detail)
  end

  test "an assigned case says who has it, an unassigned one says so" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_match(/unassigned/, entries.sole.detail)

    kase.assign!("UFF1")
    assert_match(/assigned to @UFF1/, entries.sole.detail)
  end

  test "somebody with nothing has an empty history rather than an error" do
    assert_empty Fd::MemberTimeline.for(Fd::MemberRecord.new("UNOBODY"))
  end

  def note_about(user_id = SUBJECT, body: "a soft word early goes further", **attrs)
    Fd::Note.create!({ subject_user_id: user_id, body: body, author: "UFF1" }.merge(attrs))
  end

  test "the filters are everything, cases, actions and notes" do
    assert_equal %w[all cases actions notes], Fd::MemberTimeline::KINDS.keys
  end

  test "a standing note is an entry with the words in it" do
    note_about
    entry = entries(only: "notes").sole

    assert_equal "Note", entry.title
    assert_equal "note", entry.mark
    assert_equal "a soft word early goes further", entry.said
    assert_nil entry.case_id, "a standing note belongs to no case, so it links to none"
    assert_equal "@UFF1", entry.state, "the author is the chip"
  end

  test "a note about somebody else stays on their record" do
    note_about("USOMEBODY")
    assert_empty entries(only: "notes")
  end

  test "a note on a case is not a standing note and does not appear here" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "case note", author: "UFF1")

    assert_empty entries(only: "notes")
  end

  test "a deleted note is gone from the record" do
    note_about.update!(deleted_at: Time.current, deleted_by: "UFF1")
    assert_empty entries(only: "notes")
  end

  test "notes sit in the same stream as cases and actions, newest first" do
    kase = make_case(subject: SUBJECT, opened_at: 5.days.ago)
    act_on kase, at: 3.days.ago
    note_about(created_at: 1.day.ago)

    said = entries
    assert_equal 3, said.size
    assert_equal %w[notes actions cases], said.map(&:kind)
  end
end
