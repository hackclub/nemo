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
    assert_equal "subject", entry.kind
    assert_equal %w[subject], entry.chips.first(1)
    assert_includes entry.chips, "action taken"
    assert_match(/spam/, entry.detail)
  end

  test "an open case says open rather than naming a resolution" do
    make_case(subject: SUBJECT, opened_at: 2.days.ago)
    assert_includes entries.sole.chips, "open"
  end

  test "a case they were only logged in carries their role and their reason" do
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago, category_key: "bullying")
    theirs.participants.create!(user_id: SUBJECT, role: "involved", detail: "it was aimed at them")

    entry = entries.sole
    assert_equal "logged", entry.kind
    assert_includes entry.chips, "involved"
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
    assert_includes reversal.chips, "undone"
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
    assert_equal ["subject"], entries(only: "subject").map(&:kind).uniq
    assert_equal ["logged"], entries(only: "logged").map(&:kind).uniq
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
end
